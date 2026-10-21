package shlib

import (
	"os"
	"strings"
	"testing"
)

// TestMain runs the pre-M154a suite under the documented opt-out. The
// feature defaults ON, and the suite written before it existed pins the
// byte-level protocol of that world — running it under BRACKETED_PASTE=0
// keeps every pin green AND makes the whole suite the opt-out's
// byte-identical regression proof. The paste tests set the variable
// explicitly per case.
func TestMain(m *testing.M) {
	os.Setenv("BRACKETED_PASTE", "0")
	os.Exit(m.Run())
}

// M154a (#2926): DECSET 2004 bracketed paste — on by default, opted out
// by BRACKETED_PASTE=0 in the process envp. The editor writes ?2004h when
// a line read opens and ?2004l when the line submits or the editor exits;
// ESC[200~ .. ESC[201~ stages literal bytes that commit as ONE edit
// (embedded newlines paint as ^J and submit as one script).

// TestBracketedEnableOnByDefault pins the enable/disable byte contract:
// the enable opens a line read (Repaint, and the post-command prompt the
// front-ends paint through PromptBytes), the disable precedes the submit
// newline and is the only output on EOF.
func TestBracketedEnableOnByDefault(t *testing.T) {
	t.Setenv("BRACKETED_PASTE", "")
	e := NewEditor("gosh> ", &History{})
	if out := e.Repaint(); !strings.HasPrefix(string(out), "\x1b[?2004h") {
		t.Fatalf("repaint = %q, want DECSET enable first", out)
	}
	if out := e.PromptBytes(); !strings.HasPrefix(string(out), "\x1b[?2004h") {
		t.Fatalf("prompt bytes = %q, want DECSET enable first", out)
	}
	out, ev := e.Feed([]byte("echo hi\r"))
	if ev.Kind != EvSubmit || ev.Line != "echo hi" {
		t.Fatalf("submit = (%q, %+v)", out, ev)
	}
	if !strings.HasSuffix(string(out), "\x1b[?2004l\r\n") {
		t.Fatalf("submit echo = %q, want DECRST + CRLF", out)
	}
	out, ev = e.Feed([]byte("\x04"))
	if ev.Kind != EvEOF {
		t.Fatalf("eof = %+v", ev)
	}
	if string(out) != "\x1b[?2004l" {
		t.Fatalf("eof echo = %q, want bare DECRST", out)
	}
}

// TestBracketedOptOutRestoresOldBytes pins the BRACKETED_PASTE=0 contract:
// no wrap bytes are ever emitted, and the markers keep their old `n ~`
// meaning — ESC[200~ and ESC[201~ are ordinary CSI tilde sequences, i.e.
// Delete, byte-identical to before the card.
func TestBracketedOptOutRestoresOldBytes(t *testing.T) {
	t.Setenv("BRACKETED_PASTE", "0")
	e := NewEditor("gosh> ", &History{})
	if out := e.Repaint(); strings.Contains(string(out), "2004") {
		t.Fatalf("repaint under opt-out = %q, want no DECSET bytes", out)
	}
	if out := e.PromptBytes(); string(out) != "gosh> " {
		t.Fatalf("prompt bytes under opt-out = %q", out)
	}
	// A paste open is just CSI digits ~ today: Delete mid-line, and the
	// following bytes are plain text.
	out, ev := e.Feed([]byte("ab\x1b[D\x1b[200~x"))
	if ev.Kind != evNone {
		t.Fatalf("200~ under opt-out produced %+v", ev)
	}
	if got := string(e.Bytes()); got != "ax" {
		t.Fatalf("line = %q, want ax (200~ behaved as Delete)", e.Bytes())
	}
	// Same for a stray 201~ — under the opt-out it deletes like 3~.
	e.Feed([]byte("\x1b[D\x1b[201~"))
	if got := string(e.Bytes()); got != "a" {
		t.Fatalf("line = %q, want a (201~ behaved as Delete)", e.Bytes())
	}
	out, ev = e.Feed([]byte("\r"))
	if ev.Kind != EvSubmit || string(out) != "\r\n" {
		t.Fatalf("submit echo under opt-out = (%q, %+v), want bare CRLF", out, ev)
	}
	out, ev = e.Feed([]byte("\x04"))
	if ev.Kind != EvEOF || len(out) != 0 {
		t.Fatalf("eof under opt-out = (%q, %+v), want no bytes", out, ev)
	}
}

// TestBracketedPasteOneEdit pins the decode's core: the wrapped region is
// ONE pending edit — nothing submits inside the wrap, embedded newlines
// are literal line bytes, and Enter submits the whole block once.
func TestBracketedPasteOneEdit(t *testing.T) {
	t.Setenv("BRACKETED_PASTE", "")
	h := &History{}
	e := NewEditor("gosh> ", h)
	out, ev := e.Feed([]byte("\x1b[200~echo a\necho b\x1b[201~"))
	if ev.Kind != evNone {
		t.Fatalf("paste produced %+v before Enter", ev)
	}
	if got := string(e.Bytes()); got != "echo a\necho b" {
		t.Fatalf("line = %q, want the literal paste bytes", e.Bytes())
	}
	if !strings.Contains(string(out), "echo a^Jecho b") {
		t.Fatalf("paint = %q, want the ^J newline marker", out)
	}
	out, ev = e.Feed([]byte("\r"))
	if ev.Kind != EvSubmit || ev.Line != "echo a\necho b" {
		t.Fatalf("submit = (%q, %+v), want the whole block as one line", out, ev)
	}
	if len(h.Entries()) != 1 || h.Entries()[0] != "echo a\necho b" {
		t.Fatalf("history = %v, want one entry holding the block", h.Entries())
	}
}

// TestBracketedPasteSplitReads: the wrap, the content and the terminator
// can all straddle read boundaries — the kernel hands 64-byte chunks and
// the serial front-end delivers one byte at a time.
func TestBracketedPasteSplitReads(t *testing.T) {
	t.Setenv("BRACKETED_PASTE", "")
	e := NewEditor("gosh> ", &History{})
	for _, frag := range []string{"\x1b[2", "00~ec", "ho a\ne", "cho b\x1b[20", "1~"} {
		if _, ev := e.Feed([]byte(frag)); ev.Kind != evNone {
			t.Fatalf("fragment %q produced %+v", frag, ev)
		}
	}
	if got := string(e.Bytes()); got != "echo a\necho b" {
		t.Fatalf("line = %q, want echo a\\necho b", e.Bytes())
	}
	// Byte-at-a-time, including the terminator's own bytes.
	e2 := NewEditor("gosh> ", &History{})
	var ev EditEvent
	for _, c := range []byte("\x1b[200~xy\x1b[201~\r") {
		_, ev = e2.Feed([]byte{c})
	}
	if ev.Kind != EvSubmit || ev.Line != "xy" {
		t.Fatalf("byte-at-a-time paste = %+v", ev)
	}
}

// TestBracketedPasteStrayEsc: an ESC that cannot extend the terminator is
// literal content — including a second 200~ and a partial marker head.
func TestBracketedPasteStrayEsc(t *testing.T) {
	t.Setenv("BRACKETED_PASTE", "")
	e := NewEditor("gosh> ", &History{})
	e.Feed([]byte("\x1b[200~a\x1bZb\x1b[200~c\x1b[20!d\x1b[201~"))
	want := "a\x1bZb\x1b[200~c\x1b[20!d"
	if got := string(e.Bytes()); got != want {
		t.Fatalf("line = %q, want %q (stray ESCs are literal)", e.Bytes(), want)
	}
}

// TestBracketedPasteUnterminated: a paste that never closes keeps its
// bytes staged — nothing commits early — and a later chunk completes it.
func TestBracketedPasteUnterminated(t *testing.T) {
	t.Setenv("BRACKETED_PASTE", "")
	e := NewEditor("gosh> ", &History{})
	out, ev := e.Feed([]byte("\x1b[200~abc"))
	if ev.Kind != evNone || len(e.Bytes()) != 0 {
		t.Fatalf("open paste committed early: (%q, %+v)", e.Bytes(), ev)
	}
	if len(out) != 0 {
		t.Fatalf("open paste painted %q", out)
	}
	_, ev = e.Feed([]byte("def\x1b[201~\r"))
	if ev.Kind != EvSubmit || ev.Line != "abcdef" {
		t.Fatalf("completed paste = %+v", ev)
	}
}

// TestBracketedPasteBound pins the 4 KiB staging bound: an over-bound
// paste commits clipped and carries the named truncation marker inside
// the line cap.
func TestBracketedPasteBound(t *testing.T) {
	t.Setenv("BRACKETED_PASTE", "")
	e := NewEditor("gosh> ", &History{})
	payload := strings.Repeat("x", pasteMaxBytes+1000)
	e.Feed([]byte("\x1b[200~" + payload + "\x1b[201~"))
	buf := e.Bytes()
	if len(buf) > maxLineBytes {
		t.Fatalf("line = %d bytes, want <= %d", len(buf), maxLineBytes)
	}
	if !strings.HasSuffix(string(buf), " [paste truncated]") {
		t.Fatalf("line tail = %q, want the named truncation marker",
			buf[max(0, len(buf)-40):])
	}
	want := maxLineBytes - len(" [paste truncated]")
	if string(buf[:want]) != payload[:want] {
		t.Fatalf("kept %d payload bytes, want %d", len(buf), want)
	}
}

// TestBracketedStrayEndAndDelete: a lone 201~ is consumed (it is not
// Delete), while every other CSI n ~ keeps today's meaning — 3~ deletes.
func TestBracketedStrayEndAndDelete(t *testing.T) {
	t.Setenv("BRACKETED_PASTE", "")
	e := NewEditor("gosh> ", &History{})
	e.Feed([]byte("ab\x1b[D\x1b[201~")) // cursor on b; stray end: no delete
	if got := string(e.Bytes()); got != "ab" {
		t.Fatalf("stray 201~ line = %q, want ab (consumed, not Delete)", e.Bytes())
	}
	e.Feed([]byte("\x1b[3~")) // Delete: b goes
	if got := string(e.Bytes()); got != "a" {
		t.Fatalf("3~ line = %q, want a", e.Bytes())
	}
	e.Feed([]byte("cd\x1b[D\x1b[D\x1b[5~")) // 5~ keeps today's meaning: Delete
	if got := string(e.Bytes()); got != "ad" {
		t.Fatalf("5~ line = %q, want ad", e.Bytes())
	}
}

// TestPastedScriptRunsOnceThroughSourcePath: a submitted block runs the
// way `source FILE` runs — each line through runLineBodies, blanks
// skipped — and it is still ONE submit at the editor.
func TestPastedScriptRunsOnceThroughSourcePath(t *testing.T) {
	hst := newFakeHost()
	sh := NewShell(hst, &History{})
	st, act := sh.RunLineBodies("echo one\necho two\n\n", nil)
	if act != ActionContinue || st != 0 {
		t.Fatalf("script = status %d act %v", st, act)
	}
	if got := string(hst.out); got != "one\ntwo\n" {
		t.Fatalf("script output = %q, want one\\ntwo\\n", got)
	}
	// A `<<` inside the block collects the block's own following lines —
	// the runSource path, not the front-end's continuation prompt.
	hst.out = nil
	st, _ = sh.RunLineBodies("cat <<END\nbody line\nEND", nil)
	if st != 0 || string(hst.out) != "body line\n" {
		t.Fatalf("in-block heredoc = status %d output %q", st, hst.out)
	}
	if r, err := NewHeredocReader("cat <<END\nbody line\nEND"); err != nil || r.Waiting() {
		t.Fatalf("block reader = %+v, want never armed", r)
	}
}
