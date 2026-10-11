package shlib

// M98c (issue #2129): history expansion — the pure function first, then
// the editor integration (echo bytes, EvSubmit line, ring contents, and
// the error path that keeps the typed buffer).

import (
	"strings"
	"testing"
)

func TestExpandHistoryForms(t *testing.T) {
	ents := []string{"echo one", "ls /host", "echo two"}
	for _, tc := range []struct {
		line, want string
	}{
		{"!!", "echo two"},
		{"!1", "echo one"},
		{"!2", "ls /host"},
		{"!3", "echo two"},
		{"!-1", "echo two"},
		{"!-2", "ls /host"},
		{"!-3", "echo one"},
		{"!echo", "echo two"}, // newest prefix match
		{"!ls", "ls /host"},
		{"!e", "echo two"},
		{"echo !!", "echo echo two"}, // !! mid-line
		{"x !1 y", "x echo one y"},   // !N mid-line
		{"a !ls b !2 c", "a ls /host b ls /host c"},
		{"!echo tail", "echo two tail"}, // prefix stops at space
		{"!!foo", "echo twofoo"},        // !! is exactly one byte's designator
		{"^two^three", "echo three"},    // first occurrence only
		{"^two^three^", "echo three"},
		{"^echo^printf", "printf two"},
		{"^two^", "echo "}, // empty NEW
	} {
		got, changed, err := expandHistory(tc.line, ents)
		if err != nil {
			t.Fatalf("%q: err = %v", tc.line, err)
		}
		if !changed || got != tc.want {
			t.Fatalf("%q = %q (changed %v), want %q", tc.line, got, changed, tc.want)
		}
	}
}

func TestExpandHistoryFirstOccurrenceOnly(t *testing.T) {
	ents := []string{"echo echo"}
	got, changed, err := expandHistory("^echo^ls", ents)
	if err != nil || !changed || got != "ls echo" {
		t.Fatalf("^echo^ls = %q changed=%v err=%v, want \"ls echo\"", got, changed, err)
	}
}

func TestExpandHistoryCaretTailAppends(t *testing.T) {
	ents := []string{"echo one"}
	got, changed, err := expandHistory("^one^two | cat", ents)
	if err != nil || !changed || got != "echo two | cat" {
		t.Fatalf("^one^two | cat = %q changed=%v err=%v", got, changed, err)
	}
}

func TestExpandHistoryErrors(t *testing.T) {
	ents := []string{"echo one", "ls /host"}
	for _, tc := range []struct {
		line, wantMsg string
	}{
		{"!0", "gosh: !0: event not found"},
		{"!99", "gosh: !99: event not found"},
		{"!-99", "gosh: !-99: event not found"},
		{"!-0", "gosh: !-0: event not found"},
		{"!nomatch", "gosh: !nomatch: event not found"},
		{"x !99", "gosh: !99: event not found"},
		{"^x^y", "gosh: ^x^y: substitution failed"},     // x not in last line
		{"^echo^", "gosh: ^echo^: substitution failed"}, // echo IS in "ls /host"? no — last = "ls /host", echo absent
	} {
		_, changed, err := expandHistory(tc.line, ents)
		if err == nil || changed || err.Error() != tc.wantMsg {
			t.Fatalf("%q: err = %v changed=%v, want %q", tc.line, err, changed, tc.wantMsg)
		}
	}
}

func TestExpandHistoryEmptyRing(t *testing.T) {
	for _, tc := range []struct{ line, msg string }{
		{"!!", "gosh: !!: event not found"},
		{"!1", "gosh: !1: event not found"},
		{"!x", "gosh: !x: event not found"},
		{"^a^b", "gosh: ^a^b: substitution failed"},
	} {
		if _, _, err := expandHistory(tc.line, nil); err == nil || err.Error() != tc.msg {
			t.Fatalf("%q on empty ring: err = %v, want %q", tc.line, err, tc.msg)
		}
	}
}

func TestExpandHistoryLiteralBang(t *testing.T) {
	ents := []string{"echo one"}
	for _, line := range []string{
		"! -e X",     // space after
		"!\tfoo",     // tab after
		"!=x",        // = after
		"!(x",        // ( after
		"echo hi!",   // end of line
		"a !",        // lone ! word
		"'!x'",       // single quotes
		`"!x"`,       // double quotes
		"echo '!99'", // quoted mid-line
		`echo "!-1"`, // double-quoted
		`\!x`,        // backslash consumes
		`a\! b`,      // escaped mid-line → "a! b"
		"^x",         // lone caret: no second ^ → literal
	} {
		got, changed, err := expandHistory(line, ents)
		want := strings.ReplaceAll(line, `\!`, "!") // \! loses its backslash
		if err != nil || changed || got != want {
			t.Fatalf("%q = %q changed=%v err=%v, want literal %q", line, got, changed, err, want)
		}
	}
}

func TestExpandHistoryLengthBound(t *testing.T) {
	long := strings.Repeat("x", maxLineBytes)
	ents := []string{long}
	_, _, err := expandHistory("!! !1", ents) // 2048 + 1 + 2048
	if err == nil || err.Error() != "gosh: history expansion exceeds 2048 bytes" {
		t.Fatalf("over-bound err = %v", err)
	}
	got, changed, err := expandHistory("!!", ents)
	if err != nil || !changed || got != long {
		t.Fatalf("at-bound !! failed: changed=%v err=%v", changed, err)
	}
}

// Editor level: a successful expansion echoes the EXPANDED line, submits
// it, and pushes it — the typed form never reaches the ring.
func TestEditorSubmitsExpandedLine(t *testing.T) {
	hist := &History{}
	hist.Push("ls /host")
	hist.Push("echo one")
	e := NewEditor("gosh> ", hist)
	feedE(e, "!")
	out, ev := e.Feed([]byte("l\r")) // "!l" expands to the newest ls*
	if ev.Kind != EvSubmit || ev.Line != "ls /host" {
		t.Fatalf("ev = %+v, want EvSubmit \"ls /host\"", ev)
	}
	if !strings.Contains(string(out), "\r\nls /host\r\n") {
		t.Fatalf("expanded echo missing: %q", out)
	}
	ents := hist.Entries()
	if len(ents) != 3 || ents[2] != "ls /host" {
		t.Fatalf("ring = %v; the expanded line, not '!l', must land", ents)
	}
}

// An error produces no event, pushes nothing, and repaints with the typed
// line still in the buffer for editing.
func TestEditorExpansionErrorKeepsBuffer(t *testing.T) {
	hist := &History{}
	hist.Push("echo one")
	e := NewEditor("gosh> ", hist)
	feedE(e, "!9")
	out, ev := e.Feed([]byte("9\r"))
	if ev.Kind != 0 {
		t.Fatalf("error produced an event: %+v", ev)
	}
	if !strings.Contains(string(out), "\r\ngosh: !99: event not found\r\n") {
		t.Fatalf("message missing: %q", out)
	}
	if !strings.Contains(string(out), "\rgosh> !99") {
		t.Fatalf("repaint must keep the typed line: %q", out)
	}
	if len(hist.Entries()) != 1 {
		t.Fatalf("error pushed to the ring: %v", hist.Entries())
	}
	// The buffer is editable: backspace + fix + Enter works.
	out, ev = e.Feed([]byte("\x7f\x7f1\r"))
	if ev.Kind != EvSubmit || ev.Line != "echo one" {
		t.Fatalf("after fix ev = %+v, want echo one", ev)
	}
}

// A caret substitution submits the substituted line.
func TestEditorCaretSubmit(t *testing.T) {
	hist := &History{}
	hist.Push("echo one")
	e := NewEditor("gosh> ", hist)
	feedE(e, "^one^two")
	_, ev := e.Feed([]byte("\r"))
	if ev.Kind != EvSubmit || ev.Line != "echo two" {
		t.Fatalf("caret ev = %+v, want echo two", ev)
	}
}
