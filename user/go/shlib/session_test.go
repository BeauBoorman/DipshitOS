package shlib

// M98h (issue #2134): time CMD, the tab-title tracker, \? and \D, and the
// Ctrl-X Ctrl-E round trip — all over fakes: a stepped monotonic clock, a
// scripted send for the title, and an editHost whose "GOEDIT" rewrites the
// temp file.

import (
	"strings"
	"testing"
)

// stubMono swaps the shared monotonic clock for one that advances by step
// nanoseconds on every read — one read opens a timed span, the next closes
// it, so `time CMD` reports exactly step.
func stubMono(t *testing.T, step int64) {
	t.Helper()
	prev := timeMono
	t.Cleanup(func() { timeMono = prev })
	timeMono = func() int64 {
		s := now
		now += step
		return s
	}
}

var now int64

// --- time CMD ---------------------------------------------------------------

func TestTimeRunsEachClass(t *testing.T) {
	stubMono(t, 420_000_000) // 0.42s per span

	h := newFakeHost()
	run, sh := session(h)
	sh.RunLine("fn greet() { echo hello }")

	if st := run("time echo hi"); st != 0 {
		t.Fatalf("time echo: st=%d", st)
	}
	if st := run("time grep x /host/NOSUCH.TXT"); st != 1 {
		t.Fatalf("time grep (tool): st=%d", st)
	}
	if st := run("time greet"); st != 0 {
		t.Fatalf("time fn: st=%d", st)
	}
	if st := run("time GONE.BIN arg"); st != 43 {
		t.Fatalf("time external: st=%d, want the fake's 43", st)
	}
	out := h.outString()
	for _, want := range []string{"hi\n", "hello\n"} {
		if !strings.Contains(out, want) {
			t.Fatalf("output %q lacks %q", out, want)
		}
	}
	if n := strings.Count(out, "real 0.42s\n"); n != 4 {
		t.Fatalf("real lines = %d, want 4: %q", n, out)
	}
}

func TestTimePipesRedirectsAndCapture(t *testing.T) {
	stubMono(t, 100_000_000)
	h := newFakeHost()
	run, _ := session(h)

	// c.out is the redirect target; real still lands on the terminal.
	run("time echo hi > /host/T.TXT")
	if got := string(h.files["/host/T.TXT"]); got != "hi\n" {
		t.Fatalf("T.TXT = %q, want the command output only", got)
	}
	out := h.outString()
	if !strings.Contains(out, "real 0.10s\n") {
		t.Fatalf("real line missing from terminal: %q", out)
	}

	// The capture holds only the command's output; real goes to host — and
	// lands BEFORE the outer echo, because the substitution runs first.
	h2 := newFakeHost()
	run2, _ := session(h2)
	run2("echo [$(time echo hi)]")
	if got := h2.outString(); got != "real 0.10s\n[hi]\n" {
		t.Fatalf("capture output = %q, want real then [hi]", got)
	}

	// A pipe carries the command's output, not the timing line.
	h3 := newFakeHost()
	run3, _ := session(h3)
	run3("time echo hi | cat")
	if got := h3.outString(); !strings.Contains(got, "hi\n") {
		t.Fatalf("pipe output = %q", got)
	}
}

func TestTimeExitStillExits(t *testing.T) {
	stubMono(t, 1_000_000)
	h := newFakeHost()
	_, sh := session(h)
	_, act := sh.RunLine("time exit 3")
	if act != ActionExit {
		t.Fatalf("time exit 3: act=%v, want ActionExit", act)
	}
	if !strings.Contains(h.outString(), "real ") {
		t.Fatal("no real line before the exit")
	}
}

func TestFormatReal(t *testing.T) {
	cases := map[int64]string{
		0:                 "0.00s",
		420_000_000:       "0.42s",
		999_999_999:       "0.99s",
		12_345_000_000:    "12.34s",
		3_721_000_000_000: "3721.00s",
	}
	for ns, want := range cases {
		if got := formatReal(ns); got != want {
			t.Errorf("formatReal(%d) = %q, want %q", ns, got, want)
		}
	}
}

// --- tab title ----------------------------------------------------------------

func TestTitleFor(t *testing.T) {
	cases := []struct{ prefix, pwd, want string }{
		{"Sh", "/", "Sh — /"},
		{"Term", "/", "Term — /"},
		{"Sh", "/docs", "Sh — docs"},
		{"Sh", "/a/b/c", "Sh — c"},
	}
	for _, tc := range cases {
		if got := TitleFor(tc.prefix, tc.pwd); got != tc.want {
			t.Errorf("TitleFor(%q,%q) = %q, want %q", tc.prefix, tc.pwd, got, tc.want)
		}
	}
	// 24-byte cap on a rune boundary: "Sh — " is 7, so a 25-byte tail cuts
	// to 17; a multi-byte tail never splits a rune.
	long := "/d" + strings.Repeat("x", 30)
	got := TitleFor("Sh", long)
	if len(got) > 24 || !strings.HasPrefix(got, "Sh — ") {
		t.Errorf("TitleFor long = %q (%d bytes)", got, len(got))
	}
	runes := "/\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9"
	if got := TitleFor("Sh", runes); len(got) > 24 {
		t.Errorf("rune tail cut mid-rune: %q (%d bytes)", got, len(got))
	}
}

func TestTitleSyncSendsOnChangeAndRetries(t *testing.T) {
	var ts TitleSync
	var sent []string
	ok := true
	send := func(s string) bool {
		if ok {
			sent = append(sent, s)
		}
		return ok
	}
	ts.Sync("Sh — /", send)
	ts.Sync("Sh — /", send)
	ts.Sync("Sh — docs", send)
	if len(sent) != 2 || sent[0] != "Sh — /" || sent[1] != "Sh — docs" {
		t.Fatalf("sent = %v, want two sends on change only", sent)
	}
	// A refused ack retries the same title next call, not just next change.
	ok = false
	ts.Sync("Sh — new", send)
	ok = true
	ts.Sync("Sh — new", send)
	if len(sent) != 3 || sent[2] != "Sh — new" {
		t.Fatalf("after refused ack: sent = %v", sent)
	}
	// No seat: no send at all, no state swallowed.
	ts2 := TitleSync{}
	ts2.Sync("Sh — /", nil)
	ts2.Sync("Sh — /", send)
	if len(sent) != 4 || sent[3] != "Sh — /" {
		t.Fatalf("nil send must not mark the title sent: %v", sent)
	}
}

// --- Ctrl-X Ctrl-E ------------------------------------------------------------

// editHost's "GOEDIT" rewrites the temp file the way a saved buffer would.
type editHost struct {
	fakeHost
	editBody   string
	editStatus int64
	editErr    bool
	editPath   string // the temp path GOEDIT was handed
}

func (h *editHost) RunExternal(name string, args []string) (int64, error) {
	if name == editApp {
		if h.editErr {
			return 0, ErrNotFound
		}
		h.editPath = args[0]
		h.files[args[0]] = []byte(h.editBody)
		return 7, nil
	}
	return h.fakeHost.RunExternal(name, args)
}

func (h *editHost) WaitExternal(pid int64) (int64, error) {
	return h.editStatus, nil
}

func TestEditorCtrlXCtrlE(t *testing.T) {
	e := NewEditor("gosh> ", &History{})
	feedE(e, "echo hi")
	_, ev := e.Feed([]byte{0x18, 0x05})
	if ev.Kind != EvEdit || ev.Line != "echo hi" {
		t.Fatalf("0x18 0x05 = %v %q, want EvEdit echo hi", ev.Kind, ev.Line)
	}
	if e.Value() != "" {
		t.Fatalf("buffer not cleared: %q", e.Value())
	}
	// A non-Ctrl-E byte drops the prefix and inserts normally.
	e2 := NewEditor("gosh> ", &History{})
	feedE(e2, "a")
	out, ev := e2.Feed([]byte{0x18, 'x'})
	if ev.Kind != evNone || e2.Value() != "ax" {
		t.Fatalf("0x18 x: kind=%v buf=%q", ev.Kind, e2.Value())
	}
	if string(out) == "" {
		t.Fatal("the dropped prefix's byte must still paint")
	}
	// Ctrl-E alone still ends the line.
	e3 := NewEditor("gosh> ", &History{})
	feedE(e3, "ab")
	e3.Feed([]byte{0x01}) // Home
	_, ev = e3.Feed([]byte{0x05})
	if ev.Kind != evNone || e3.Caret() != 2 {
		t.Fatalf("0x05 alone: kind=%v caret=%d", ev.Kind, e3.Caret())
	}
}

func TestEditLineRoundTrip(t *testing.T) {
	h := &editHost{editBody: "echo one\n\necho two\n"}
	h.fakeHost = *newFakeHost()
	sh := NewShell(h, &History{})
	lines, err := sh.EditLine("echo one")
	if err != nil {
		t.Fatalf("EditLine: %v", err)
	}
	if len(lines) != 2 || lines[0] != "echo one" || lines[1] != "echo two" {
		t.Fatalf("lines = %v", lines)
	}
	// GOEDIT got the temp path and the file is gone afterwards.
	if !strings.Contains(h.editPath, ".GEDIT") {
		t.Fatalf("GOEDIT argv = %q, want the temp path", h.editPath)
	}
	for p := range h.files {
		if strings.Contains(p, ".GEDIT") {
			t.Fatalf("temp %s not removed", p)
		}
	}
}

func TestEditLineFailures(t *testing.T) {
	// Missing GOEDIT.
	h := &editHost{editErr: true}
	h.fakeHost = *newFakeHost()
	sh := NewShell(h, &History{})
	if _, err := sh.EditLine("x"); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("missing GOEDIT: err = %v", err)
	}
	// Nonzero exit.
	h2 := &editHost{editStatus: 2}
	h2.fakeHost = *newFakeHost()
	sh2 := NewShell(h2, &History{})
	if _, err := sh2.EditLine("x"); err == nil {
		t.Fatal("nonzero GOEDIT exit must fail")
	}
	// Unreadable read-back: deny via a path the fake can't read... the temp
	// is gone by then, so assert the write-failure path instead.
	h3 := &editHost{}
	h3.fakeHost = *newFakeHost()
	h3.writeErr = true
	sh3 := NewShell(h3, &History{})
	if _, err := sh3.EditLine("x"); err == nil {
		t.Fatal("temp write failure must fail")
	}
	// An empty saved file runs nothing and is not an error.
	h4 := &editHost{editBody: ""}
	h4.fakeHost = *newFakeHost()
	sh4 := NewShell(h4, &History{})
	lines, err := sh4.EditLine("x")
	if err != nil || len(lines) != 0 {
		t.Fatalf("empty edit: lines=%v err=%v", lines, err)
	}
}

func TestEditLineCtrlCAbandons(t *testing.T) {
	h := &editHost{editBody: "echo ran"}
	h.fakeHost = *newFakeHost()
	h.intr = true
	h.ttyIn = []byte{0x03}
	h.probeAfter = 2
	sh := NewShell(h, &History{})
	if _, err := sh.EditLine("x"); err == nil || !strings.Contains(err.Error(), "interrupted") {
		t.Fatalf("Ctrl-C during GOEDIT: err = %v, want interrupted", err)
	}
	if len(h.kills) != 1 {
		t.Fatalf("kills = %v, want the GOEDIT pid armed once", h.kills)
	}
}

// --- \? and \D ---------------------------------------------------------------

func TestPromptStatusAndDuration(t *testing.T) {
	stubMono(t, 12_300_000_000)
	h := newFakeHost()
	run, sh := session(h)
	facts := PromptFactsFor(sh, h.Principal, "v")

	if got := ExpandPrompt(`\?`, facts()); got != "0" {
		t.Fatalf(`\? before any line = %q, want 0`, got)
	}
	run("echo ok")
	if got := ExpandPrompt(`\?`, facts()); got != "0" {
		t.Fatalf(`\? after success = %q`, got)
	}
	if got := ExpandPrompt(`\D`, facts()); got != "12s" {
		t.Fatalf(`\D after 12.3s line = %q, want 12s`, got)
	}
	run("grep x /host/NOSUCH.TXT")
	if got := ExpandPrompt(`\?`, facts()); got != "1" {
		t.Fatalf(`\? after failure = %q`, got)
	}
	// An empty line leaves both values.
	run("")
	f := facts()
	if f.Status != 1 || f.DurationNs != 12_300_000_000 {
		t.Fatalf("empty line: status=%d dur=%d", f.Status, f.DurationNs)
	}
	// `\D{fmt}` prints the brace literally (the strftime form is not ours).
	if got := ExpandPrompt(`\D{%S}`, facts()); got != "12s{%S}" {
		t.Fatalf(`\D{...} = %q`, got)
	}
}

func TestFormatDurationTable(t *testing.T) {
	cases := map[int64]string{
		0:                  "0.0s",
		400_000_000:        "0.4s",
		9_999_000_000:      "9.9s",
		12_300_000_000:     "12s",
		59_900_000_000:     "59s",
		184_000_000_000:    "3m04s",
		3_599_000_000_000:  "59m59s",
		3_721_000_000_000:  "1h02m",
		90_000_000_000_000: "25h00m",
	}
	for ns, want := range cases {
		if got := formatDuration(ns); got != want {
			t.Errorf("formatDuration(%d) = %q, want %q", ns, got, want)
		}
	}
}
