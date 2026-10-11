package shlib

import (
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"
)

// feedE pushes bytes through a fresh editor and returns the tty output.
func feedE(e *Editor, s string) string {
	out, _ := e.Feed([]byte(s))
	return string(out)
}

// TestEditorTyping pins insert, backspace and the repaint protocol: every
// keystroke repaints `\r` + prompt + line (spaces over the old tail) and
// repositions the cursor with `\r` + prompt + prefix.
func TestEditorTyping(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	out := feedE(e, "ec")
	// Every keystroke repaints; the final paint is the current state.
	if !strings.HasSuffix(out, "\rgosh> ec") {
		t.Fatalf("insert repaint = %q", out)
	}
	out = feedE(e, "\x7f")
	// One space overwrites the erased tail, then the cursor repositions.
	if !strings.HasSuffix(out, "\rgosh> e \rgosh> e") {
		t.Fatalf("backspace repaint = %q", out)
	}
	out = feedE(e, "ho")
	if !strings.HasSuffix(out, "gosh> eho") {
		t.Fatalf("mid insert = %q", out)
	}
	// Ctrl-A, Ctrl-E move within the line.
	out = feedE(e, "\x01x")
	if !strings.Contains(out, "\rgosh> xeho") {
		t.Fatalf("ctrl-a insert = %q", out)
	}
	out = feedE(e, "\x05!")
	if !strings.Contains(out, "xeho!") {
		t.Fatalf("ctrl-e append = %q", out)
	}
}

func TestEditorUnicodeCursorEditsStayOnRuneBoundaries(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "AöB")
	if e.cur != len("AöB") {
		t.Fatalf("initial cursor = %d, want %d", e.cur, len("AöB"))
	}

	feedE(e, "\x1b[D")
	if e.cur != len("Aö") {
		t.Fatalf("first left cursor = %d, want %d", e.cur, len("Aö"))
	}
	feedE(e, "\x1b[D")
	if e.cur != 1 {
		t.Fatalf("second left cursor = %d, want 1", e.cur)
	}
	feedE(e, "\x1b[C")
	if e.cur != len("Aö") {
		t.Fatalf("right cursor = %d, want %d", e.cur, len("Aö"))
	}
	feedE(e, "\x7f")
	if string(e.buf) != "AB" || e.cur != 1 {
		t.Fatalf("backspace left buf=%q cur=%d, want AB at 1", e.buf, e.cur)
	}

	feedE(e, "ø")
	if string(e.buf) != "AøB" || e.cur != len("Aø") {
		t.Fatalf("Unicode insert left buf=%q cur=%d, want AøB at %d",
			e.buf, e.cur, len("Aø"))
	}
	feedE(e, "\x1b[3~")
	if string(e.buf) != "Aø" || e.cur != len("Aø") {
		t.Fatalf("delete left buf=%q cur=%d, want Aø at %d",
			e.buf, e.cur, len("Aø"))
	}

	transposed := NewEditor("gosh> ", &History{})
	feedE(transposed, "AöB")
	feedE(transposed, "\x14")
	if string(transposed.buf) != "ABö" || transposed.cur != len("ABö") {
		t.Fatalf("transpose left buf=%q cur=%d, want ABö at %d",
			transposed.buf, transposed.cur, len("ABö"))
	}
}

// TestEditorSubmit pins the submit protocol: a bare \r\n (M73d #1628:
// the next prompt is the FRONT-END's post-RunLine write, the reference
// shell loop's order — not part of the submit echo), the pushed history,
// and Ctrl-C / Ctrl-D.
func TestEditorSubmit(t *testing.T) {
	h := &History{}
	e := NewEditor("gosh> ", h)
	out, ev := e.Feed([]byte("echo hi\r"))
	if ev.Kind != EvSubmit || ev.Line != "echo hi" {
		t.Fatalf("submit event = %+v", ev)
	}
	if !strings.HasSuffix(string(out), "\r\n") {
		t.Fatalf("submit repaint = %q, want to end bare at CRLF (no prompt after it)", out)
	}
	if len(h.Entries()) != 1 || h.Entries()[0] != "echo hi" {
		t.Fatalf("history = %v", h.Entries())
	}
	// Ctrl-C abandons the line with ^C and a fresh prompt.
	out, ev = e.Feed([]byte("junk\x03"))
	if ev.Kind != EvCancel || !strings.Contains(string(out), "^C\r\n") {
		t.Fatalf("ctrl-c = (%q, %+v)", out, ev)
	}
	// Ctrl-D on an empty line is EOF; on a non-empty line it is ignored.
	_, ev = e.Feed([]byte("x\x04"))
	if ev.Kind != evNone {
		t.Fatalf("ctrl-d non-empty = %+v", ev)
	}
	_, ev = e.Feed([]byte("\x7f\x04"))
	if ev.Kind != EvEOF {
		t.Fatalf("ctrl-d empty = %+v", ev)
	}
}

// TestEditorHistory pins Up/Down recall, the return to the live line, and
// dup-collapse.
func TestEditorHistory(t *testing.T) {
	h := &History{}
	e := NewEditor("gosh> ", h)
	feedE(e, "one\r")
	feedE(e, "two\r")
	feedE(e, "two\r") // dup of the last: collapsed
	if n := len(h.Entries()); n != 2 {
		t.Fatalf("history = %v", h.Entries())
	}
	out := feedE(e, "\x1b[A") // Up
	if !strings.Contains(out, "gosh> two") {
		t.Fatalf("Up = %q", out)
	}
	out = feedE(e, "\x1b[A")
	if !strings.Contains(out, "gosh> one") {
		t.Fatalf("Up Up = %q", out)
	}
	out = feedE(e, "\x1b[B") // Down
	if !strings.Contains(out, "gosh> two") {
		t.Fatalf("Down = %q", out)
	}
	out = feedE(e, "\x1b[B") // past the end: back to the live (empty) line
	if strings.Contains(out, "two") || !strings.Contains(out, "gosh> ") {
		t.Fatalf("Down past end = %q", out)
	}
	// The submitted recall is exact (the gate's history proof).
	_, ev := e.Feed([]byte("\x1b[A\r"))
	if ev.Kind != EvSubmit || ev.Line != "two" {
		t.Fatalf("recalled submit = %+v", ev)
	}
}

// TestEditorCSISplit pins CSI sequences arriving across two chunks (the
// kernel hands 64-byte reads; an escape can straddle the boundary).
func TestEditorCSISplit(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "abc")
	out := feedE(e, "\x1b")
	if out != "" {
		t.Fatalf("lone ESC wrote %q", out)
	}
	out = feedE(e, "[D") // now the Left arrives
	if !strings.Contains(out, "\rgosh> ab") {
		t.Fatalf("split CSI = %q", out)
	}
	// The cursor sits between b and c: typing inserts mid-line.
	out = feedE(e, "X")
	if !strings.Contains(out, "abXc") {
		t.Fatalf("mid-line insert = %q", out)
	}
}

// TestEditorKeys pins Home/End/Delete/Ctrl-K/Ctrl-U/Ctrl-W/Ctrl-L.
func TestEditorKeys(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "echo hello")
	out := feedE(e, "\x1b[Hx") // Home + insert
	if !strings.Contains(out, "xecho hello") {
		t.Fatalf("home insert = %q", out)
	}
	out = feedE(e, "\x7f\x7f") // delete the x (backspace)
	out = feedE(e, "\x1b[F!")  // End + append
	if !strings.Contains(out, "echo hello!") {
		t.Fatalf("end append = %q", out)
	}
	out = feedE(e, "\x1b[3~") // Delete key: no-op at the end
	if out != "" {
		t.Fatalf("delete at end wrote %q", out)
	}
	// Five Lefts from "echo hello!" put the cursor on hello's 'e'.
	out = feedE(e, "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[3~")
	if !strings.Contains(out, "echo hllo!") {
		t.Fatalf("delete mid-line = %q", out)
	}
	out = feedE(e, "\x0b") // Ctrl-K at the end: nothing to kill
	_ = out
	out = feedE(e, "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x0b") // kill to end from 'h'
	if !strings.Contains(out, "echo h") {
		t.Fatalf("ctrl-k = %q", out)
	}
	out = feedE(e, "\x15") // Ctrl-U: kill to start (tail spaces clear the old text)
	if strings.Contains(out, "echo") || !strings.HasSuffix(out, "\rgosh> ") {
		t.Fatalf("ctrl-u = %q", out)
	}
	out = feedE(e, "echo two words\x17") // Ctrl-W kills "words"
	if !strings.Contains(out, "echo two ") {
		t.Fatalf("ctrl-w = %q", out)
	}
	out = feedE(e, "\x0c") // Ctrl-L clears and repaints
	if !strings.HasPrefix(out, "\x1b[2J\x1b[H") {
		t.Fatalf("ctrl-l = %q", out)
	}
}

// TestEditorCompletion pins Tab: single completes with a space, several
// complete to the common prefix, a second Tab lists, none is a no-op.
func TestEditorCompletion(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	listed := false
	e.Complete = func(req CompleteRequest) []string {
		switch req.Word {
		case "ec":
			return []string{"echo "}
		case "c":
			return []string{"cat ", "cd ", "clear "}
		case "GO":
			return []string{"GOSH.ELF", "GONET.ELF"}
		}
		if req.Word == "list" {
			listed = true
		}
		return nil
	}
	out := feedE(e, "ec\t")
	if !strings.Contains(out, "gosh> echo ") {
		t.Fatalf("single completion = %q", out)
	}
	// Several candidates that share nothing beyond the word itself: the
	// first Tab opens the completion menu (M80m #1729) where it used to ring
	// a bell, and the second Tab cycles to the first candidate.
	feedE(e, "\r")
	out = feedE(e, "c\t")
	if !strings.Contains(out, "\r\ncat    cd     clear\r\n") {
		t.Fatalf("completion menu = %q", out)
	}
	if !strings.HasSuffix(out, "\rgosh> c") {
		t.Fatalf("menu repaint = %q, want the line under the listing", out)
	}
	if listed {
		t.Fatalf("the no-candidate branch fired early")
	}
	out = feedE(e, "\t")
	if string(e.buf) != "cat " || e.cur != 4 {
		t.Fatalf("menu cycle = %q cur %d, want \"cat \" at 4", e.buf, e.cur)
	}
	// File candidates complete to the common prefix without a space.
	feedE(e, "\r")
	out = feedE(e, "GO\t")
	if !strings.Contains(out, "gosh> GO") {
		t.Fatalf("file prefix = %q", out)
	}
}

// TestHistoryBound pins the ring bound.
func TestHistoryBound(t *testing.T) {
	h := &History{}
	for i := 0; i < historyMax+10; i++ {
		h.Push(string(rune('a'+i%26)) + string(rune('0'+i/26)))
	}
	if len(h.Entries()) != historyMax {
		t.Fatalf("history bound = %d, want %d", len(h.Entries()), historyMax)
	}
}

// TestEditorBurstDrain pins the serial front-end's burst contract: one read
// can carry several whole lines (the class-B harness types its script in a
// single burst), Feed returns at most one event and holds the rest, so the
// session loop must feed with a nil chunk until Pending() is false. Without
// that drain every line after the first is typed but never run, which is
// exactly how the retargeted live-sh gate failed.
func TestEditorBurstDrain(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	burst := "echo abc\rcd /data\recho PWD=$PWD\rstatus43\r\x1b[A\r"
	out, ev := e.Feed([]byte(burst))
	if len(out) == 0 {
		t.Fatal("burst produced no tty output")
	}
	if ev.Kind != EvSubmit || ev.Line != "echo abc" {
		t.Fatalf("first event = kind %d line %q, want submit %q", ev.Kind, ev.Line, "echo abc")
	}
	if !e.Pending() {
		t.Fatal("editor dropped the rest of the burst instead of holding it")
	}
	var lines []string
	for e.Pending() {
		_, ev = e.Feed(nil)
		if ev.Kind != EvSubmit {
			t.Fatalf("drained event = kind %d, want submit", ev.Kind)
		}
		lines = append(lines, ev.Line)
	}
	want := []string{"cd /data", "echo PWD=$PWD", "status43", "status43"}
	if len(lines) != len(want) {
		t.Fatalf("drained %d lines %q, want %d", len(lines), lines, len(want))
	}
	for i := range want {
		if lines[i] != want[i] {
			t.Fatalf("drained line %d = %q, want %q", i, lines[i], want[i])
		}
	}
	// History took every *distinct* line in order, including the recall --
	// Push collapses a dup of the last entry, so the Up-recall of status43
	// does not add a fifth.
	if h := e.hist.Entries(); len(h) != 4 || h[3] != "status43" {
		t.Fatalf("history = %q, want four entries ending in status43", h)
	}
}

// TestEditorLineCap pins the interactive line bound: past maxLineBytes a
// keystroke answers with a bell instead of growing the buffer, and Tab
// completion cannot slip past the cap either.
func TestEditorLineCap(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, strings.Repeat("x", maxLineBytes))
	if len(e.buf) != maxLineBytes {
		t.Fatalf("line = %d bytes, want %d", len(e.buf), maxLineBytes)
	}
	out := feedE(e, "y")
	if len(e.buf) != maxLineBytes {
		t.Fatalf("line grew past the cap: %d bytes", len(e.buf))
	}
	if !strings.Contains(out, "\x07") {
		t.Fatalf("overflow keystroke = %q, want a bell", out)
	}
	// A completion that would pass the cap is refused the same way.
	e2 := NewEditor("gosh> ", &History{})
	e2.Complete = func(req CompleteRequest) []string { return []string{req.Word + strings.Repeat("z", 64)} }
	feedE(e2, strings.Repeat("q", maxLineBytes))
	out = feedE(e2, "\t")
	if len(e2.buf) != maxLineBytes {
		t.Fatalf("completion grew past the cap: %d bytes", len(e2.buf))
	}
	if !strings.Contains(out, "\x07") {
		t.Fatalf("capped completion = %q, want a bell", out)
	}
}

func TestEditorRejectsUnicodeRuneAtomicallyAtLineCap(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	e.buf = []byte(strings.Repeat("x", maxLineBytes-1))
	e.cur = len(e.buf)

	out, _ := e.Feed([]byte{0xC3})
	if !strings.Contains(string(out), "\x07") {
		t.Fatalf("overflowing rune lead = %q, want a bell", out)
	}
	e.Feed([]byte{0xB6})
	if len(e.buf) != maxLineBytes-1 || !utf8.Valid(e.buf) {
		t.Fatalf("rejected rune changed line to len=%d valid=%v", len(e.buf), utf8.Valid(e.buf))
	}

	feedE(e, "y")
	if len(e.buf) != maxLineBytes || e.buf[len(e.buf)-1] != 'y' {
		t.Fatalf("input after rejected rune = len %d, tail %q; want ASCII y accepted", len(e.buf), e.buf[len(e.buf)-1:])
	}
}

func TestSearchRejectsUnicodeRuneAtomicallyAtQueryCap(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	e.searching = true
	e.query = []byte(strings.Repeat("a", maxSearchQuery-1))

	out, _ := e.Feed([]byte{0xC3})
	if !strings.Contains(string(out), "\x07") {
		t.Fatalf("overflowing query rune lead = %q, want a bell", out)
	}
	e.Feed([]byte{0xB6})
	if len(e.query) != maxSearchQuery-1 || !utf8.Valid(e.query) {
		t.Fatalf("rejected query rune changed query to len=%d valid=%v", len(e.query), utf8.Valid(e.query))
	}
}

// A lone ESC must not eat the next character. Escape followed by anything but
// '[' is not a sequence this keymap consumes, so the ESC is dropped and the
// character is ground input -- otherwise pressing Escape and then typing
// silently loses the keystroke. The kernel's keymap emits ESC [ X for every
// arrow/Home/End, so nothing legitimate arrives in the lone-ESC shape.
func TestEditorLoneEscDoesNotEatTheNextByte(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	// ESC in its own chunk: the editor parks in the escape state.
	if _, ev := e.Feed([]byte{0x1b}); ev.Kind != evNone {
		t.Fatalf("bare ESC produced event %d", ev.Kind)
	}
	// The next byte must land in the line, not vanish.
	out, ev := e.Feed([]byte("x"))
	if ev.Kind != evNone {
		t.Fatalf("typing after ESC produced event %d", ev.Kind)
	}
	if string(e.buf) != "x" {
		t.Fatalf("buf = %q want \"x\": the byte after a lone ESC was dropped", e.buf)
	}
	if !strings.Contains(string(out), "x") {
		t.Fatalf("repaint = %q, want the character painted", out)
	}
	// ESC inside a chunk behaves the same way.
	e2 := NewEditor("gosh> ", &History{})
	feedE(e2, "ab")
	repaint := feedE(e2, "\x1bcd")
	if string(e2.buf) != "abcd" {
		t.Fatalf("buf = %q want \"abcd\"", e2.buf)
	}
	if !strings.Contains(repaint, "abcd") {
		t.Fatalf("repaint = %q, want abcd", repaint)
	}
	// And the real sequences still work: ESC [ D is one cursor-left.
	e3 := NewEditor("gosh> ", &History{})
	feedE(e3, "ab")
	feedE(e3, "\x1b[D")
	if e3.cur != 1 {
		t.Fatalf("cur = %d want 1 after ESC [ D", e3.cur)
	}
}

// --- reverse-i-search (M45 SH3), retargeted into GOSH by M68b (#1450) ------

// drainFeed feeds a chunk the way the session loop does -- one Feed, then
// Feed(nil) until the editor holds nothing -- and collects every submitted
// line. This is the contract the serial front-end needs (a burst can carry
// several lines), and it is the only way search acceptance can be observed.
func drainFeed(e *Editor, s string) (string, []string) {
	w, ev := e.Feed([]byte(s))
	out := string(w)
	var lines []string
	if ev.Kind == EvSubmit {
		lines = append(lines, ev.Line)
	}
	for e.Pending() {
		var next []byte
		next, ev = e.Feed(nil)
		out += string(next)
		if ev.Kind == EvSubmit {
			lines = append(lines, ev.Line)
		}
	}
	return out, lines
}

// TestSearchGateChoreography walks the exact byte sequence live-sh-complete
// stages: run a command, then Ctrl+R + "status" + Enter (accept) + Enter
// (submit), and asserts the recall-and-rerun the gate counts.
func TestSearchGateChoreography(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	e.Complete = func(req CompleteRequest) []string {
		if strings.HasPrefix("help", req.Word) {
			return []string{"help "}
		}
		return nil
	}
	// The gate runs `status43`, completes `hel` -> `help` and runs it.
	drainFeed(e, "status43\r")
	drainFeed(e, "hel\t\r")

	out, lines := drainFeed(e, "\x12status\r\r")
	if !strings.Contains(out, "reverse-i-search") {
		t.Fatalf("paint = %q, want the reverse-i-search prompt", out)
	}
	if len(lines) != 1 || lines[0] != "status43" {
		t.Fatalf("submitted %q, want exactly one status43 recall", lines)
	}
	// The recalled line went through the engine again, so "status43" appears
	// twice in the ring -- which is the gate's whole point (it counts
	// `status43: alive` twice).
	if h := e.hist.Entries(); len(h) != 3 || h[0] != "status43" || h[1] != "help " || h[2] != "status43" {
		t.Fatalf("history = %q, want [status43 hel-p-completed status43]", h)
	}
}

// TestSearchPaintShowsTheMatch pins what the user sees: the query, the
// newest-first substring match, and the match loaded as the live line.
func TestSearchPaintShowsTheMatch(t *testing.T) {
	h := &History{}
	h.Push("alpha-one")
	h.Push("beta-two")
	h.Push("alpha-three") // newest containing "alpha"
	e := NewEditor("gosh> ", h)
	feedE(e, "draft")
	out := feedE(e, "\x12")
	if !strings.Contains(out, "(reverse-i-search)`_`: (no match)") {
		t.Fatalf("empty-query paint = %q", out)
	}
	out = feedE(e, "a")
	if !strings.Contains(out, "(reverse-i-search)`a`: alpha-three") {
		t.Fatalf("first-byte paint = %q", out)
	}
	if string(e.buf) != "alpha-three" {
		t.Fatalf("buf = %q, want the match loaded", e.buf)
	}
	out = feedE(e, "lpha")
	if !strings.Contains(out, "(reverse-i-search)`alpha`: alpha-three") {
		t.Fatalf("paint = %q", out)
	}
	// A query that matches nothing says so and leaves the line as it was.
	out = feedE(e, "zz")
	if !strings.Contains(out, "(no match)") {
		t.Fatalf("no-match paint = %q", out)
	}
	if string(e.buf) != "alpha-three" {
		t.Fatalf("buf = %q, want the previous match kept", e.buf)
	}
}

// TestSearchCancelRestoresTheDraft: Esc and Ctrl-C both put the line back the
// way it was before Ctrl+R, so a search can never lose work.
func TestSearchCancelRestoresTheDraft(t *testing.T) {
	h := &History{}
	h.Push("status43")
	for _, cancel := range []string{"\x1b", "\x03"} {
		e := NewEditor("gosh> ", h)
		feedE(e, "half-typed")
		drainFeed(e, "\x12status")
		if string(e.buf) != "status43" {
			t.Fatalf("mid-search buf = %q", e.buf)
		}
		out := feedE(e, cancel)
		if e.searching {
			t.Fatalf("cancel %q left search mode on", cancel)
		}
		if string(e.buf) != "half-typed" || e.cur != len("half-typed") {
			t.Fatalf("cancel %q restored %q (cur %d), want half-typed", cancel, e.buf, e.cur)
		}
		if !strings.Contains(out, "half-typed") {
			t.Fatalf("cancel %q paint = %q, want the draft repainted", cancel, out)
		}
	}
}

// TestSearchBackspaceTrimsTheQuery: Backspace edits the QUERY, not the line,
// and re-runs the match on the shorter query.
func TestSearchBackspaceTrimsTheQuery(t *testing.T) {
	h := &History{}
	h.Push("status43")
	h.Push("status99")
	e := NewEditor("gosh> ", h)
	drainFeed(e, "\x12status")
	if string(e.buf) != "status99" {
		t.Fatalf("buf = %q want the newest match", e.buf)
	}
	out := feedE(e, "\x7f")
	if !strings.Contains(out, "(reverse-i-search)`statu") {
		t.Fatalf("paint = %q, want the trimmed query", out)
	}
	for len(e.query) > 1 { // trim down to a single byte
		feedE(e, "\x7f")
	}
	out = feedE(e, "\x7f") // 1 -> 0: the query is empty and nothing matches
	if len(e.query) != 0 {
		t.Fatalf("query = %q want empty", e.query)
	}
	if !strings.Contains(out, "(reverse-i-search)`_`: (no match)") {
		t.Fatalf("paint at the empty query = %q", out)
	}
	// One backspace past empty is a no-op with NO repaint, exactly as SH.BIN's
	// search_handle does it (query_len 0 -> return without redraw).
	if got := feedE(e, "\x7f"); got != "" {
		t.Fatalf("backspace past empty painted %q, want nothing", got)
	}
	if len(e.query) != 0 {
		t.Fatalf("backspace past empty left query %q", e.query)
	}
}

func TestSearchBackspaceRemovesWholeUnicodeRune(t *testing.T) {
	h := &History{}
	h.Push("ö")
	e := NewEditor("gosh> ", h)
	drainFeed(e, "\x12ö")
	if string(e.query) != "ö" {
		t.Fatalf("query = %q, want ö", e.query)
	}
	out := feedE(e, "\x7f")
	if len(e.query) != 0 {
		t.Fatalf("query after backspace = %q, want empty", e.query)
	}
	if !strings.Contains(out, "(reverse-i-search)`_`: (no match)") {
		t.Fatalf("empty-query paint = %q", out)
	}
}

// TestSearchQueryIsBounded: the query buffer does not grow without limit.
func TestSearchQueryIsBounded(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "\x12")
	feedE(e, strings.Repeat("q", maxSearchQuery))
	if len(e.query) != maxSearchQuery {
		t.Fatalf("query = %d bytes want %d", len(e.query), maxSearchQuery)
	}
	out := feedE(e, "q")
	if len(e.query) != maxSearchQuery {
		t.Fatalf("query grew past the cap: %d", len(e.query))
	}
	if !strings.Contains(out, "\x07") {
		t.Fatalf("overflow paint = %q, want a bell", out)
	}
}

// TestSearchAcceptedLineStillSubmits: after an accept, the NEXT return
// submits, and the editor is back in ground mode (typed characters land in
// the line again rather than feeding a query).
func TestSearchAcceptedLineStillSubmits(t *testing.T) {
	h := &History{}
	h.Push("echo hi")
	e := NewEditor("gosh> ", h)
	// Ctrl+R + query leaves the match loaded while search mode is still on.
	drainFeed(e, "\x12echo")
	if string(e.buf) != "echo hi" {
		t.Fatalf("buf = %q want the match loaded mid-search", e.buf)
	}
	if !e.searching {
		t.Fatal("query entry left search mode on by itself")
	}
	// The FIRST Return accepts the recall and must NOT also submit it.
	w, lines := drainFeed(e, "\r")
	if e.searching {
		t.Fatal("accept left search mode on")
	}
	if len(lines) != 0 {
		t.Fatalf("accept also submitted %q", lines)
	}
	if string(e.buf) != "echo hi" {
		t.Fatalf("buf = %q want the accepted recall", e.buf)
	}
	if !strings.Contains(w, "gosh> ") {
		t.Fatalf("accept paint = %q, want the prompt repainted", w)
	}
	// The SECOND Return submits the recalled line, like any accepted line.
	_, lines = drainFeed(e, "\r")
	if len(lines) != 1 || lines[0] != "echo hi" {
		t.Fatalf("after accept, Return submitted %q, want the recall", lines)
	}
	// Ground mode again: typing edits the fresh line.
	feedE(e, "X")
	if string(e.buf) != "X" {
		t.Fatalf("buf = %q, want post-search typing in a fresh line", e.buf)
	}
}

// TestSearchCancelRestoresMidLineCursor: cancel puts the draft back with the
// cursor where it sat, not only at end-of-line (TestSearchCancelRestoresTheDraft
// types to the end). A search must not lose a mid-line edit position.
func TestSearchCancelRestoresMidLineCursor(t *testing.T) {
	h := &History{}
	h.Push("status43")
	e := NewEditor("gosh> ", h)
	feedE(e, "abcdef")
	feedE(e, "\x1b[D\x1b[D\x1b[D") // cursor between c and d
	if e.cur != 3 {
		t.Fatalf("setup cur = %d want 3", e.cur)
	}
	drainFeed(e, "\x12status")
	out := feedE(e, "\x1b")
	if e.searching {
		t.Fatal("cancel left search mode on")
	}
	if string(e.buf) != "abcdef" || e.cur != 3 {
		t.Fatalf("cancel restored %q cur %d, want abcdef at 3", e.buf, e.cur)
	}
	if !strings.Contains(out, "abcdef") {
		t.Fatalf("cancel paint = %q, want the draft", out)
	}
}

// TestSearchCancelMidChunkDefersRemainder: an accept or cancel that ends
// search mid-chunk must hold the rest for the ground loop, the same path
// `Ctrl+R query CR CR` uses to accept then submit. Without the deferral the
// trailing bytes would vanish.
func TestSearchCancelMidChunkDefersRemainder(t *testing.T) {
	h := &History{}
	h.Push("status43")
	e := NewEditor("gosh> ", h)
	feedE(e, "half")
	_, ev := e.Feed([]byte("\x12st\x1bXYZ"))
	if ev.Kind != evNone {
		t.Fatalf("cancel chunk produced event %d", ev.Kind)
	}
	if !e.searching {
		t.Fatal("Ctrl+R did not enter search")
	}
	if !e.Pending() {
		t.Fatal("Ctrl+R dropped the rest of the chunk")
	}
	// Drain: query bytes, then Esc ends search and holds XYZ.
	for e.Pending() && e.searching {
		_, ev = e.Feed(nil)
		if ev.Kind != evNone {
			t.Fatalf("drain produced event %d", ev.Kind)
		}
	}
	if e.searching {
		t.Fatal("cancel left search mode on")
	}
	if string(e.buf) != "half" {
		t.Fatalf("buf after cancel = %q want the draft", e.buf)
	}
	if !e.Pending() {
		t.Fatal("cancel dropped the trailing ground bytes")
	}
	_, ev = e.Feed(nil)
	if ev.Kind != evNone {
		t.Fatalf("deferred typing produced event %d", ev.Kind)
	}
	if string(e.buf) != "halfXYZ" {
		t.Fatalf("deferred typing = %q want halfXYZ", e.buf)
	}
}

// TestSearchCtrlRMidChunkDefersQuery: Ctrl+R that arrives with query bytes
// in the same chunk must not insert those bytes into the line. The rest of
// the chunk is the query, consumed on the next Feed.
func TestSearchCtrlRMidChunkDefersQuery(t *testing.T) {
	h := &History{}
	h.Push("status43")
	e := NewEditor("gosh> ", h)
	feedE(e, "hello")
	_, ev := e.Feed([]byte("\x12status"))
	if ev.Kind != evNone {
		t.Fatalf("Ctrl+R chunk produced event %d", ev.Kind)
	}
	if !e.searching {
		t.Fatal("Ctrl+R did not enter search")
	}
	if string(e.buf) != "hello" {
		t.Fatalf("buf = %q, query bytes leaked into the line", e.buf)
	}
	if !e.Pending() {
		t.Fatal("Ctrl+R dropped the query bytes")
	}
	e.Feed(nil)
	if string(e.query) != "status" {
		t.Fatalf("query = %q want status", e.query)
	}
	if string(e.buf) != "status43" {
		t.Fatalf("buf = %q want the match loaded", e.buf)
	}
}

// --- M69f1 (#1537): the persistent-recall file shape ---------------------

// TestHistoryLoadReadsOldestFirst pins the format SaveHistory writes: UTF-8,
// LF, one command per line, oldest first.
func TestHistoryLoadReadsOldestFirst(t *testing.T) {
	var h History
	h.Load([]byte("one\ntwo\nthree\n"))
	if got, want := strings.Join(h.Entries(), ","), "one,two,three"; got != want {
		t.Fatalf("entries = %q want %q", got, want)
	}
}

func TestPastePreservesUTF8Runes(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	line := "echo ┌─┐你 ppp"
	feedE(e, "echo ")
	for _, r := range []rune("┌─┐你") {
		encoded := []byte(string(r))
		for i, b := range encoded {
			out, _ := e.Feed([]byte{b})
			if i+1 < len(encoded) && len(out) != 0 {
				t.Fatalf("partial UTF-8 rune %q repainted after byte %d: %q",
					r, i+1, out)
			}
			if i+1 == len(encoded) && !strings.Contains(string(out), string(r)) {
				t.Fatalf("complete UTF-8 rune %q missing from repaint: %q", r, out)
			}
		}
	}
	feedE(e, " ppp")
	_, ev := e.Feed([]byte("\n"))
	if ev.Kind != EvSubmit {
		t.Fatalf("event = %v, want submit", ev.Kind)
	}
	if ev.Line != line {
		t.Fatalf("submitted line = %q, want %q", ev.Line, line)
	}
}

// TestHistoryLoadSkipsTruncatedTail: a half-written append (no trailing LF)
// costs one line, never the whole file.
func TestHistoryLoadSkipsTruncatedTail(t *testing.T) {
	var h History
	h.Load([]byte("one\ntwo\npar"))
	if got, want := strings.Join(h.Entries(), ","), "one,two"; got != want {
		t.Fatalf("entries = %q want %q", got, want)
	}
}

// TestHistoryLoadTolerances: the empty file, a lone partial line, CRLF input
// and blank lines all reduce to the same ring the session would have built.
func TestHistoryLoadTolerances(t *testing.T) {
	var h History
	h.Load(nil)
	if got := h.Entries(); len(got) != 0 {
		t.Fatalf("empty load = %q want no entries", got)
	}
	h.Load([]byte("partial"))
	if got := h.Entries(); len(got) != 0 {
		t.Fatalf("partial-only load = %q want no entries", got)
	}
	h.Load([]byte("one\r\n\r\ntwo\r\n"))
	if got, want := strings.Join(h.Entries(), ","), "one,two"; got != want {
		t.Fatalf("crlf load = %q want %q", got, want)
	}
}

// TestHistoryLoadIsBounded: the file cannot grow the ring past historyMax.
func TestHistoryLoadIsBounded(t *testing.T) {
	var body []byte
	for i := 0; i < historyMax*2; i++ {
		body = append(body, []byte(fmt.Sprintf("line-%03d\n", i))...)
	}
	var h History
	h.Load(body)
	if got := len(h.Entries()); got != historyMax {
		t.Fatalf("ring after load = %d entries want %d", got, historyMax)
	}
}

// --- word motion, kill ring, transpose (M80l #1728) ------------------------

// TestEditorWordMotion pins alt-f/alt-b: the end of the word under the
// cursor, the next word's end from whitespace, the word's start backwards,
// and silence at the line edges.
func TestEditorWordMotion(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "echo hello world")
	feedE(e, "\x01")  // Home: start from the front
	feedE(e, "\x1bf") // alt-f from 0: the end of "echo"
	if e.cur != 4 {
		t.Fatalf("alt-f cur = %d want 4", e.cur)
	}
	feedE(e, "\x1bf") // from the space: the end of "hello"
	if e.cur != 10 {
		t.Fatalf("alt-f from whitespace cur = %d want 10", e.cur)
	}
	feedE(e, "\x1bb") // back to the start of "hello"
	if e.cur != 5 {
		t.Fatalf("alt-b cur = %d want 5", e.cur)
	}
	feedE(e, "\x1bb") // over the space, to the start of "echo"
	if e.cur != 0 {
		t.Fatalf("alt-b over a space cur = %d want 0", e.cur)
	}
	if out := feedE(e, "\x1bb"); out != "" {
		t.Fatalf("alt-b at the line start wrote %q, want nothing", out)
	}
	// Three more alt-f walk the cursor to the last byte.
	feedE(e, "\x1bf\x1bf\x1bf")
	if e.cur != len(e.buf) || string(e.buf) != "echo hello world" {
		t.Fatalf("alt-f to the end = cur %d buf %q", e.cur, e.buf)
	}
	if out := feedE(e, "\x1bf"); out != "" {
		t.Fatalf("alt-f at the line end wrote %q, want nothing", out)
	}
}

// TestEditorAltKillWords pins alt-d (forward) and alt-backspace (backward),
// including the readline detail that alt-d from whitespace eats the
// whitespace and the word behind it.
func TestEditorAltKillWords(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "echo hello world")
	feedE(e, "\x01")         // Home: start from the front
	out := feedE(e, "\x1bd") // alt-d at 0: kills "echo"
	if string(e.buf) != " hello world" {
		t.Fatalf("alt-d = %q", e.buf)
	}
	if !strings.Contains(out, " hello world") {
		t.Fatalf("alt-d repaint = %q", out)
	}
	feedE(e, "\x1bd") // from the leading space: kills " hello"
	if string(e.buf) != " world" {
		t.Fatalf("alt-d from whitespace = %q", e.buf)
	}
	// With nothing after the cursor, alt-d leaves the line alone.
	feedE(e, "\x05") // Ctrl-E: to the end
	feedE(e, "\x1bd")
	if string(e.buf) != " world" || e.cur != 6 {
		t.Fatalf("alt-d at the end = %q cur %d", e.buf, e.cur)
	}
	// Alt-Backspace is the same word-back kill as Ctrl-W, over ESC DEL and
	// ESC BS alike.
	e2 := NewEditor("gosh> ", &History{})
	feedE(e2, "echo hello world")
	feedE(e2, "\x1b\x7f")
	if string(e2.buf) != "echo hello " {
		t.Fatalf("alt-backspace = %q", e2.buf)
	}
	feedE(e2, "\x1b\x7f")
	if string(e2.buf) != "echo " {
		t.Fatalf("second alt-backspace = %q", e2.buf)
	}
	feedE(e2, "\x1b\x08")
	if string(e2.buf) != "" {
		t.Fatalf("alt-backspace on ESC BS = %q", e2.buf)
	}
}

// TestEditorKillRingYank pins Ctrl-Y: it brings the last kill back at the
// cursor from any kill chord, an empty ring is silent, and an oversized
// yank bells instead of growing past the cap.
func TestEditorKillRingYank(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	if out := feedE(e, "\x19"); out != "" {
		t.Fatalf("Ctrl-Y on an empty ring wrote %q", out)
	}
	feedE(e, "echo hello")
	feedE(e, "\x17") // Ctrl-W kills "hello"
	feedE(e, "\x01") // Home
	feedE(e, "\x19") // Ctrl-Y, at the front of the line
	if string(e.buf) != "helloecho " {
		t.Fatalf("yank = %q", e.buf)
	}
	if e.cur != 5 {
		t.Fatalf("yank left the cursor at %d want 5", e.cur)
	}
	// Ctrl-K's kill is yankable from the other end of the line.
	e2 := NewEditor("gosh> ", &History{})
	feedE(e2, "echo hi")
	feedE(e2, "\x01\x0b") // Home, Ctrl-K
	feedE(e2, "\x19")
	if string(e2.buf) != "echo hi" {
		t.Fatalf("ctrl-k yank = %q", e2.buf)
	}
	// The line cap still applies: a full line in the ring plus a byte on the
	// line is one byte too many.
	e3 := NewEditor("gosh> ", &History{})
	feedE(e3, strings.Repeat("x", maxLineBytes))
	feedE(e3, "\x17") // the whole line goes into the ring
	feedE(e3, "y")
	out := feedE(e3, "\x19")
	if !strings.Contains(out, "\x07") {
		t.Fatalf("oversized yank = %q, want a bell", out)
	}
	if len(e3.buf) != 1 {
		t.Fatalf("oversized yank grew the line to %d bytes", len(e3.buf))
	}
}

// TestEditorConsecutiveKillMerge pins the readline merge rule: a second kill
// in the same direction, with the cursor still where the first one left it,
// grows the same ring entry -- backward prepends, forward appends -- and a
// cursor move that actually moves starts a fresh entry.
func TestEditorConsecutiveKillMerge(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "echo hello world")
	feedE(e, "\x17\x17") // Ctrl-W twice: "world", then "hello "
	feedE(e, "\x19")     // Ctrl-Y: both words, in line order
	if string(e.buf) != "echo hello world" {
		t.Fatalf("merged backward yank = %q", e.buf)
	}
	// Forward kills append instead of prepending.
	e2 := NewEditor("gosh> ", &History{})
	feedE(e2, "echo hello world")
	feedE(e2, "\x01")       // Home
	feedE(e2, "\x1bd\x1bd") // alt-d twice
	feedE(e2, "\x19")
	if string(e2.buf) != "echo hello world" {
		t.Fatalf("merged forward yank = %q", e2.buf)
	}
	// A real cursor move in between breaks the chain: the ring keeps only
	// the second kill, so the yank reads " two", not "one two".
	e3 := NewEditor("gosh> ", &History{})
	feedE(e3, "one two three")
	feedE(e3, "\x01")   // Home
	feedE(e3, "\x1bd")  // kill "one"
	feedE(e3, "\x1b[C") // Right: the chain is over
	feedE(e3, "\x1bd")  // kill "two"
	feedE(e3, "\x19")   // Ctrl-Y
	if string(e3.buf) != " two three" {
		t.Fatalf("yank after a break = %q", e3.buf)
	}
	// A move that cannot move is not an edit: Right at the end of the line
	// changes nothing, so the chain survives and the third Ctrl-W merges
	// into the same entry.
	e4 := NewEditor("gosh> ", &History{})
	feedE(e4, "echo hello world")
	feedE(e4, "\x17\x17") // Ctrl-W twice: the ring holds "hello world"
	feedE(e4, "\x1b[C")   // Right at the end: nothing moves
	feedE(e4, "\x17")     // Ctrl-W: merges with the two before it
	if string(e4.buf) != "" {
		t.Fatalf("third ctrl-w = %q", e4.buf)
	}
	feedE(e4, "\x19")
	if string(e4.buf) != "echo hello world" {
		t.Fatalf("three-kill yank = %q", e4.buf)
	}
}

// TestEditorTranspose pins Ctrl-T at the end of the line, between two
// characters, and at the line start where there is nothing to transpose.
func TestEditorTranspose(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	if out := feedE(e, "\x14"); out != "" {
		t.Fatalf("Ctrl-T on an empty line wrote %q", out)
	}
	feedE(e, "a")
	if out := feedE(e, "\x14"); out != "" {
		t.Fatalf("Ctrl-T on a one-byte line wrote %q", out)
	}
	feedE(e, "bc") // "abc", cursor at 3
	feedE(e, "\x14")
	if string(e.buf) != "acb" || e.cur != 3 {
		t.Fatalf("Ctrl-T at the end = %q cur %d", e.buf, e.cur)
	}
	feedE(e, "\x01")   // Home
	feedE(e, "\x1b[C") // Right: between "a" and "c"
	feedE(e, "\x14")
	if string(e.buf) != "cab" || e.cur != 2 {
		t.Fatalf("Ctrl-T mid-line = %q cur %d", e.buf, e.cur)
	}
	feedE(e, "\x01")
	if out := feedE(e, "\x14"); out != "" {
		t.Fatalf("Ctrl-T at the line start wrote %q", out)
	}
	if string(e.buf) != "cab" {
		t.Fatalf("Ctrl-T at the line start changed the line to %q", e.buf)
	}
}

// TestEditorAltPrefixAcrossChunks pins the ESC-prefixed chords when the
// escape and its letter arrive in separate reads, the shape the kernel's
// 64-byte tty reads can produce.
func TestEditorAltPrefixAcrossChunks(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "echo hello")
	feedE(e, "\x01") // Home
	if out, ev := e.Feed([]byte{0x1b}); ev.Kind != evNone || len(out) != 0 {
		t.Fatalf("lone ESC = (%q, %+v)", out, ev)
	}
	out, ev := e.Feed([]byte("f"))
	if ev.Kind != evNone {
		t.Fatalf("ESC f produced event %d", ev.Kind)
	}
	if e.cur != 4 {
		t.Fatalf("ESC f across chunks = cur %d want 4", e.cur)
	}
	if !strings.Contains(string(out), "echo hello") {
		t.Fatalf("ESC f repaint = %q", out)
	}
	// ESC DEL across chunks is Alt-Backspace.
	feedE(e, "\x1b")
	feedE(e, "\x7f")
	if string(e.buf) != " hello" {
		t.Fatalf("ESC DEL across chunks = %q", e.buf)
	}
}

// TestEditorKillBytesUnchanged pins the byte output of the three kill chords
// this card rewired, no-ops included: Ctrl-K at the end, Ctrl-W's tail
// overwrite and Ctrl-U on an empty line all still repaint exactly as before.
func TestEditorKillBytesUnchanged(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "echo")
	if out := feedE(e, "\x0b"); out != "\rgosh> echo\rgosh> echo" {
		t.Fatalf("ctrl-k at the end = %q", out)
	}
	out := feedE(e, "\x17")
	if !strings.HasSuffix(out, "    \rgosh> ") || string(e.buf) != "" || e.cur != 0 {
		t.Fatalf("ctrl-w = %q, buf %q, cur %d", out, e.buf, e.cur)
	}
	if out := feedE(e, "\x15"); out != "\rgosh> \rgosh> " {
		t.Fatalf("ctrl-u on an empty line = %q", out)
	}
}

// --- the completion menu (M80m #1729) ---------------------------------------

// menuHook is the completer the menu tests share: "c" is the ambiguous word
// the card is about, "ec" the single-candidate case, and everything else a
// miss.
func menuHook(req CompleteRequest) []string {
	switch req.Word {
	case "ec":
		return []string{"echo "}
	case "echo ":
		return []string{"echo "}
	case "c":
		return []string{"cat ", "cd ", "clear "}
	}
	return nil
}

// TestCompletionMenuColumns pins the layout: column-major, padded to the
// widest entry plus the gap, no trailing blanks, and a narrower grid folds
// the listing into fewer columns.
func TestCompletionMenuColumns(t *testing.T) {
	cands := []string{"cat ", "cd ", "clear "}
	got := menuRows(cands, 80, 0)
	if len(got) != 1 || got[0] != "cat    cd     clear" {
		t.Fatalf("menuRows at 80 = %q", got)
	}
	if strings.HasSuffix(got[0], " ") {
		t.Fatalf("menu row ends in blanks: %q", got[0])
	}
	// 12 columns fit one 7-wide entry: one candidate per row.
	got = menuRows(cands, 12, 0)
	want := []string{"cat", "cd", "clear"}
	if len(got) != len(want) {
		t.Fatalf("menuRows at 12 = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("menuRows at 12 row %d = %q want %q", i, got[i], want[i])
		}
	}
	// A degenerate width still lays out one column rather than dividing by
	// zero or looping.
	if got = menuRows(cands, 1, 0); len(got) != 3 {
		t.Fatalf("menuRows at 1 col = %q", got)
	}
	if menuRows(nil, 80, 0) != nil {
		t.Fatalf("menuRows of no candidates should be nil")
	}
}

// TestCompletionMenuPages pins paging: 30 three-character names in a 15-column
// grid are three columns by ten rows, so the first Tab shows eight rows and
// the next Tab shows the last two.
func TestCompletionMenuPages(t *testing.T) {
	var cands []string
	for i := 1; i <= 30; i++ {
		cands = append(cands, "f"+fmt.Sprintf("%02d", i))
	}
	e := NewEditor("gosh> ", &History{})
	e.SetCols(15)
	e.Complete = func(req CompleteRequest) []string { return cands }
	feedE(e, "f")
	out := feedE(e, "\t")
	page0 := []string{
		"f01  f11  f21", "f02  f12  f22", "f03  f13  f23", "f04  f14  f24",
		"f05  f15  f25", "f06  f16  f26", "f07  f17  f27", "f08  f18  f28",
	}
	for _, row := range page0 {
		if !strings.Contains(out, "\r\n"+row+"\r\n") {
			t.Fatalf("page 0 missing row %q in %q", row, out)
		}
	}
	if strings.Contains(out, "f09") {
		t.Fatalf("page 0 leaked the second page: %q", out)
	}
	// The next Tab pages rather than cycling.
	out = feedE(e, "\t")
	for _, row := range []string{"f09  f19  f29", "f10  f20  f30"} {
		if !strings.Contains(out, "\r\n"+row+"\r\n") {
			t.Fatalf("page 1 missing row %q in %q", row, out)
		}
	}
	if string(e.buf) != "f" {
		t.Fatalf("paging changed the line to %q", e.buf)
	}
	// The last page pages no further: the next Tab starts cycling.
	out = feedE(e, "\t")
	if string(e.buf) != "f01" || e.cur != 3 {
		t.Fatalf("cycle after the last page = %q cur %d", e.buf, e.cur)
	}
	if strings.Contains(out, "f02") {
		t.Fatalf("the post-page Tab painted a page again: %q", out)
	}
}

// TestCompletionMenuCycle pins the cycle order, the wrap, and that the text
// after the completed word survives every cycle.
func TestCompletionMenuCycle(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	e.Complete = menuHook
	feedE(e, "c")
	feedE(e, "\t") // the menu
	for _, want := range []struct {
		line string
		cur  int
	}{{"cat ", 4}, {"cd ", 3}, {"clear ", 6}, {"cat ", 4}} {
		feedE(e, "\t")
		if string(e.buf) != want.line || e.cur != want.cur {
			t.Fatalf("cycle = %q cur %d, want %q at %d", e.buf, e.cur, want.line, want.cur)
		}
	}
	// A tail after the cursor is preserved: the cycle replaces the word, not
	// the rest of the line.
	e2 := NewEditor("gosh> ", &History{})
	e2.Complete = menuHook
	feedE(e2, "c tail")
	feedE(e2, "\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D") // back onto the "c"
	feedE(e2, "\t")                             // the menu
	feedE(e2, "\t")                             // cycle
	if string(e2.buf) != "cat  tail" || e2.cur != 4 {
		t.Fatalf("cycle with a tail = %q cur %d", e2.buf, e2.cur)
	}
}

// TestCompletionMenuDismisses pins the dismissal rule: any byte that is not
// Tab closes the menu, and the keystroke still does its own job.
func TestCompletionMenuDismisses(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	e.Complete = menuHook
	feedE(e, "c")
	feedE(e, "\t")
	if !e.menuOn {
		t.Fatalf("the menu should be up after the first Tab")
	}
	out := feedE(e, "x")
	if e.menuOn {
		t.Fatalf("a printable key did not dismiss the menu")
	}
	if string(e.buf) != "cx" {
		t.Fatalf("the printable key did not insert: %q", e.buf)
	}
	if !strings.HasSuffix(out, "\rgosh> cx") {
		t.Fatalf("dismiss + insert repaint = %q", out)
	}
	// A chord dismisses too, and the word is recomputed on the next Tab.
	// Backspace is the chord here precisely because Ctrl-W on "cx" would
	// kill the whole word and leave nothing to complete.
	feedE(e, "\x7f")
	if e.menuOn {
		t.Fatalf("Backspace did not dismiss the menu")
	}
	if string(e.buf) != "c" {
		t.Fatalf("Backspace left %q, want \"c\"", e.buf)
	}
	// Arrows dismiss as well: the ESC of the sequence is enough.
	feedE(e, "\t")
	if !e.menuOn {
		t.Fatalf("the menu should be up again")
	}
	feedE(e, "\x1b[D")
	if e.menuOn {
		t.Fatalf("an arrow did not dismiss the menu")
	}
}

// TestCompletionMenuSingleCandidate pins the one-candidate rule: it inserts,
// and a word that already spells the candidate is answered with silence
// rather than a one-row menu.
func TestCompletionMenuSingleCandidate(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	e.Complete = menuHook
	feedE(e, "ec")
	out := feedE(e, "\t")
	if string(e.buf) != "echo " || e.menuOn {
		t.Fatalf("single candidate = %q menuOn %v", e.buf, e.menuOn)
	}
	if !strings.HasSuffix(out, "\rgosh> echo ") {
		t.Fatalf("single candidate repaint = %q", out)
	}
	// The word is already the whole candidate: nothing to add, nothing to
	// show.
	if out := feedE(e, "\t"); out != "" {
		t.Fatalf("a complete word answered %q, want silence", out)
	}
	if e.menuOn {
		t.Fatalf("a complete word opened a menu")
	}
}

// TestCompletionMenuSubmitContract pins the M73d contract with a menu up:
// Enter still echoes the bare newline and no prompt, and submits the line as
// it stands.
func TestCompletionMenuSubmitContract(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	e.Complete = menuHook
	feedE(e, "c")
	feedE(e, "\t")
	out, ev := e.Feed([]byte("\r"))
	if ev.Kind != EvSubmit || ev.Line != "c" {
		t.Fatalf("submit with a menu up = %+v", ev)
	}
	if string(out) != "\r\n" {
		t.Fatalf("submit echo = %q, want the bare CRLF", out)
	}
}

// TestCompletionMenuRespectsLineCap pins the cap on a cycle: a candidate
// that would push the line past maxLineBytes bells and changes nothing.
func TestCompletionMenuRespectsLineCap(t *testing.T) {
	// Two candidates with nothing in common, so the menu opens rather than
	// the common-prefix insert: the first fits the cap exactly, the second
	// is a byte too long for it.
	fits := strings.Repeat("y", maxLineBytes)
	tooLong := strings.Repeat("z", maxLineBytes+1)
	e := NewEditor("gosh> ", &History{})
	e.Complete = func(req CompleteRequest) []string {
		return []string{fits, tooLong}
	}
	feedE(e, "q")
	feedE(e, "\t")
	if !e.menuOn {
		t.Fatalf("the menu should be up")
	}
	feedE(e, "\t") // cycle to the first candidate: exactly the cap
	if string(e.buf) != fits {
		t.Fatalf("first cycle = %d bytes, want %d", len(e.buf), maxLineBytes)
	}
	out := feedE(e, "\t") // cycle to the longer one: over the cap
	if string(e.buf) != fits {
		t.Fatalf("the oversized cycle changed the line to %d bytes", len(e.buf))
	}
	if !strings.Contains(out, "\x07") {
		t.Fatalf("oversized cycle = %d bytes of output, want a bell", len(out))
	}
}

// TestSetCols pins the width seam the menu lays out against.
func TestSetCols(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	if e.menuCols() != defaultCols {
		t.Fatalf("default width = %d want %d", e.menuCols(), defaultCols)
	}
	e.SetCols(24)
	if e.menuCols() != 24 {
		t.Fatalf("SetCols(24) = %d", e.menuCols())
	}
	e.SetCols(0) // nonsense restores the default
	if e.menuCols() != defaultCols {
		t.Fatalf("SetCols(0) = %d want the default", e.menuCols())
	}
}

// TestEditorSharesBoundedLineBuffer pins the seam introduced by #1710 and
// used by #1730: the editor embeds the same bounded buffer that the GUI text
// fields use, while prompt expansion and repainting still see that buffer's
// bytes and caret. In particular, NewEditor must initialize the bound; a
// zero-value embedded LineBuffer would silently make SetValue unbounded.
func TestEditorSharesBoundedLineBuffer(t *testing.T) {
	cwd := "/data"
	e := NewEditor(`\w> `, &History{})
	e.SetPromptFacts(promptFactsForTest(&cwd))

	// Exercise the embedded API first: its bound and storage are the editor's
	// storage, not a detached copy used only by the GUI controls.
	e.SetValue(strings.Repeat("x", maxLineBytes+1))
	if got := e.Value(); len(got) != maxLineBytes {
		t.Fatalf("bounded value = %d bytes, want %d", len(got), maxLineBytes)
	}
	if got := e.Caret(); got != maxLineBytes {
		t.Fatalf("bounded caret = %d, want %d", got, maxLineBytes)
	}
	e.Clear()
	if e.Value() != "" || e.Caret() != 0 {
		t.Fatalf("cleared buffer = %q at %d", e.Value(), e.Caret())
	}

	e.SetValue("abc")
	if !e.InsertByte('X') || e.Value() != "abcX" || e.Caret() != 4 {
		t.Fatalf("embedded insert = %q at %d", e.Value(), e.Caret())
	}
	if !e.Backspace() || e.Value() != "abc" || e.Caret() != 3 {
		t.Fatalf("embedded backspace = %q at %d", e.Value(), e.Caret())
	}
	if got, want := string(e.Repaint()), "\r/data> abc\r/data> abc"; got != want {
		t.Fatalf("editor repaint with embedded buffer = %q, want %q", got, want)
	}
}

// --- prompt escapes (M80n #1730) -------------------------------------------

// promptFactsForTest is the provider the prompt tests share: a user in /data
// on the seeded hostname, with a settable cwd so a `cd` can be simulated.
func promptFactsForTest(cwd *string) func() PromptFacts {
	return func() PromptFacts {
		return PromptFacts{User: "user", Host: "virelai", Cwd: *cwd}
	}
}

// TestPromptEscapePaintsAtWidth pins the whole point of the card: a prompt
// that expands is painted EXPANDED, measured in cells, and the bytes the
// front-end writes after a command are the same bytes the editor repaints.
func TestPromptEscapePaintsAtWidth(t *testing.T) {
	cwd := "/data"
	e := NewEditor(`\w> `, &History{})
	e.SetPromptFacts(promptFactsForTest(&cwd))
	if got := string(e.PromptBytes()); got != "/data> " {
		t.Fatalf("expansion at construction = %q", got)
	}
	out := feedE(e, "x")
	if out != "\r/data> x\r/data> x" {
		t.Fatalf("expanded paint = %q", out)
	}
	// A `cd` moves the directory; the next repaint of a new line follows it,
	// which is why the front-end re-reads the template after every command.
	cwd = "/data/sub"
	out = string(e.Repaint())
	if !strings.HasPrefix(out, "\r/data/sub> ") {
		t.Fatalf("repaint after cd = %q", out)
	}
	if got := string(e.PromptBytes()); got != "/data/sub> " {
		t.Fatalf("PromptBytes after cd = %q", got)
	}
}

// TestPromptColourTailMath pins the width contract where a byte count would
// visibly break: a coloured prompt is many bytes but few cells, so the tail
// the repaint overwrites must be counted in CELLS. One backspace on "abc"
// leaves exactly one cell of tail -- a byte count would write nine.
func TestPromptColourTailMath(t *testing.T) {
	cwd := "/data"
	e := NewEditor("\x1b[32m\\w\x1b[0m$ ", &History{})
	e.SetPromptFacts(promptFactsForTest(&cwd))
	const want = "\x1b[32m/data\x1b[0m$ "
	if got := string(e.PromptBytes()); got != want {
		t.Fatalf("colour expansion = %q want %q", got, want)
	}
	if w := VisibleWidth(want); w != 7 {
		t.Fatalf("the expanded prompt is %d cells, want 7 (\"%s\")", w, want)
	}
	if len(want) <= 7 {
		t.Fatalf("fixture is not a byte/cell mismatch: %d bytes", len(want))
	}
	feedE(e, "abc")
	out := feedE(e, "\x7f")
	// The tail between the shortened line and the repositioning CR is ONE
	// space: the cell the deleted character occupied, and no more.
	if !strings.HasSuffix(out, "ab \r\x1b[32m/data\x1b[0m$ ab") {
		t.Fatalf("tail after backspace = %q", out)
	}
	if strings.Contains(out, "         \r") {
		t.Fatalf("the tail was measured in bytes, not cells: %q", out)
	}
}

// TestPromptPlainIsByteIdentical is the regression guard for every front-end
// and gate that never asked for an escape: with no facts provider, a plain
// prompt paints exactly the bytes it always painted.
func TestPromptPlainIsByteIdentical(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	// One keystroke per Feed, because the editor repaints per byte: a chunk
	// of two would return two paints concatenated.
	if out := feedE(e, "e"); out != "\rgosh> e\rgosh> e" {
		t.Fatalf("plain paint = %q", out)
	}
	if out := feedE(e, "c"); out != "\rgosh> ec\rgosh> ec" {
		t.Fatalf("plain second paint = %q", out)
	}
	out := feedE(e, "\x7f")
	if out != "\rgosh> e \rgosh> e" {
		t.Fatalf("plain backspace = %q", out)
	}
	// A template with escapes and no provider is written AS WRITTEN: the
	// editor never silently eats a backslash a front-end did not expand.
	e2 := NewEditor(`\w> `, &History{})
	if got := string(e2.PromptBytes()); got != `\w> ` {
		t.Fatalf("unexpanded template = %q", got)
	}
}

// TestPromptRuneWidth pins that a multi-byte character costs one cell, which
// is what the rune-based VisibleWidth buys over the old byte count.
func TestPromptRuneWidth(t *testing.T) {
	e := NewEditor("é> ", &History{})
	if w := VisibleWidth("é> "); w != 3 {
		t.Fatalf("fixture width = %d want 3", w)
	}
	feedE(e, "ab")
	out := feedE(e, "\x7f")
	// One cell of tail for the deleted "b", even though the prompt is two
	// bytes wider in bytes than in cells.
	if !strings.HasSuffix(out, "a \r\u00e9> a") && !strings.HasSuffix(out, "a \r\xc3\xa9> a") {
		t.Fatalf("rune tail = %q", out)
	}
}
