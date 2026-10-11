package shlib

import (
	"strings"
	"testing"
)

// toolOut runs one tool line through the engine and returns its output and
// status (the same path a user line takes, pipes included).
func toolOut(t *testing.T, h *fakeHost, line string) (string, int) {
	t.Helper()
	h.out = nil
	sh := NewShell(h, &History{})
	st, act := sh.RunLine(line)
	if act != ActionContinue {
		t.Fatalf("%q: unexpected action", line)
	}
	return h.outString(), st
}

func TestToolboxWc(t *testing.T) {
	h := newFakeHost()
	out, st := toolOut(t, h, "printf 'a\\nb\\nc\\n' | wc -l")
	if st != 0 || strings.TrimSpace(out) != "3" {
		t.Fatalf("wc -l = (%q, %d), want 3", out, st)
	}
	out, _ = toolOut(t, h, "printf 'one two three' | wc -w")
	if strings.TrimSpace(out) != "3" {
		t.Fatalf("wc -w = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'xyz' | wc -c")
	if strings.TrimSpace(out) != "3" {
		t.Fatalf("wc -c = %q", out)
	}
	// File input through the host seam, TOOL.BIN-style output line.
	h.files["DATA.TXT"] = []byte("1\n2\n3\n")
	out, st = toolOut(t, h, "wc -l DATA.TXT")
	if st != 0 || out != "3 DATA.TXT\n" {
		t.Fatalf("wc -l FILE = (%q, %d), want \"3 DATA.TXT\"", out, st)
	}
}

func TestToolboxHeadTail(t *testing.T) {
	h := newFakeHost()
	out, _ := toolOut(t, h, "printf '1\\n2\\n3\\n4\\n5\\n' | head -n 2")
	if out != "1\n2\n" {
		t.Fatalf("head = %q", out)
	}
	out, _ = toolOut(t, h, "printf '1\\n2\\n3\\n4\\n5\\n' | tail -n 2")
	if out != "4\n5\n" {
		t.Fatalf("tail = %q", out)
	}
}

func TestToolboxGrep(t *testing.T) {
	h := newFakeHost()
	out, st := toolOut(t, h, "printf 'alpha\\nbeta\\nAlphaBeta\\n' | grep -i alpha")
	if st != 0 || out != "alpha\nAlphaBeta\n" {
		t.Fatalf("grep -i = (%q, %d)", out, st)
	}
	_, st = toolOut(t, h, "printf 'alpha' | grep zeta")
	if st != 1 {
		t.Fatalf("grep no-match status = %d, want 1", st)
	}
}

func TestToolboxSortCut(t *testing.T) {
	h := newFakeHost()
	out, _ := toolOut(t, h, "printf 'c\\na\\nb\\n' | sort")
	if out != "a\nb\nc\n" {
		t.Fatalf("sort = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'b\\na\\nb\\n' | sort -r -u")
	if out != "b\na\n" {
		t.Fatalf("sort -r -u = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'a:1:x\\nb:2:y\\n' | cut -d : -f 2")
	if out != "1\n2\n" {
		t.Fatalf("cut -d = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'a:b:c\\n' | cut -d : -f 1,3")
	if out != "a:c\n" {
		t.Fatalf("cut list = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'a:b:c\\n' | cut -d : -f 2-3")
	if out != "b:c\n" {
		t.Fatalf("cut range = %q", out)
	}
}

func TestToolboxPrintf(t *testing.T) {
	h := newFakeHost()
	out, _ := toolOut(t, h, "printf 'x=%s n=%d 100%% done' 7 7")
	if out != "x=7 n=7 100% done" {
		t.Fatalf("printf = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'A\\nB\\tC\\\\D'")
	if out != "A\nB\tC\\D" {
		t.Fatalf("printf escapes = %q", out)
	}
}

func TestToolboxTest(t *testing.T) {
	h := newFakeHost()
	cases := []struct {
		line string
		want int
	}{
		{"test -n hello", 0},
		{"test -z ''", 0},
		{"test -n ''", 1},
		{`[ abc = abc ]`, 0},
		{`[ abc != xyz ]`, 0},
		{`[ 5 -lt 9 ]`, 0},
		{`[ 5 -ge 9 ]`, 1},
		{`[ -e DATA.TXT ]`, 0},
		{`[ -e /host/NOPE.TXT ]`, 1},
		{`[ one two ]`, 2}, // missing ] is a usage error
	}
	h.files["DATA.TXT"] = []byte("x")
	for _, tc := range cases {
		_, st := toolOut(t, h, tc.line)
		if st != tc.want {
			t.Fatalf("%q status = %d, want %d", tc.line, st, tc.want)
		}
	}
}

// TestToolboxCutEmptyDelim pins the empty-delimiter refusal: `cut -d ""`
// tokenizes to a genuine empty word (quoting makes a word, not a separator),
// so reading byte 0 of it would panic the shell on a typed line.
func TestToolboxCutEmptyDelim(t *testing.T) {
	h := newFakeHost()
	out, st := toolOut(t, h, `printf 'a:b\n' | cut -d "" -f 1`)
	if st != 2 {
		t.Fatalf(`cut -d "" status = %d, want 2`, st)
	}
	if !strings.Contains(out, "-d needs one delimiter character") {
		t.Fatalf(`cut -d "" message = %q`, out)
	}
	// The same empty word reached through a variable is refused too
	// (an unset or empty variable expands to a real empty argument).
	h2 := newFakeHost()
	run, _ := session(h2)
	if st := run("set E="); st != 0 {
		t.Fatalf("set status = %d", st)
	}
	h2.out = nil
	if st := run(`printf 'a:b\n' | cut -d $E -f 1`); st != 2 {
		t.Fatalf(`cut -d $E status = %d, want 2`, st)
	}
	if got := h2.outString(); !strings.Contains(got, "-d needs one delimiter character") {
		t.Fatalf(`cut -d $E message = %q`, got)
	}
}

// TestToolboxNegatives pins the usage refusals.
func TestToolboxNegatives(t *testing.T) {
	h := newFakeHost()
	for _, line := range []string{"wc -x", "head -z 1", "grep", "cut -f 0", "sort -x"} {
		_, st := toolOut(t, h, line)
		if st == 0 {
			t.Fatalf("%q unexpectedly succeeded", line)
		}
	}
}

// TestToolboxPrintfEscapes pins printf's escape set to the retired Zig
// toolbox's (user/src/lib/toolbox.zig runPrintf) — \n \t \r \e \\ \0 and
// the \xHH raw byte M73a-2 (#1631) added there: the live-term burst is
// typed as exactly these escapes, and M73d (#1628) observed GOTERM
// receiving the whole format as literal text without them.
func TestToolboxPrintfEscapes(t *testing.T) {
	h := newFakeHost()
	out, st := toolOut(t, h, "printf '\\e[2J\\e[31mRED\\e[0m\\n'")
	if st != 0 || out != "\x1b[2J\x1b[31mRED\x1b[0m\n" {
		t.Fatalf("csi burst = (%q, %d)", out, st)
	}
	out, _ = toolOut(t, h, "printf '\\xE2\\x94\\x8C \\xC3\\xA9'")
	if out != "\xe2\x94\x8c \xc3\xa9" {
		t.Fatalf("hex runes = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'a\\rb\\0c\\td'")
	if out != "a\rb\x00c\td" {
		t.Fatalf("cr nul tab = %q", out)
	}
	// Not a hex pair and unknown escapes stay literal — both toolboxes
	// agree, so a mistyped escape is visible text, never a dropped byte.
	out, _ = toolOut(t, h, "printf '\\q \\xZZ \\x4'")
	if out != `\q \xZZ \x4` {
		t.Fatalf("literal escapes = %q", out)
	}
}

// --- M98e (issue #2131): tee, xargs, tr, basename, dirname -------------

func TestToolTee(t *testing.T) {
	h := newFakeHost()
	out, st := toolOut(t, h, "printf 'x\\ny\\n' | tee T.TXT")
	if st != 0 || out != "x\ny\n" || string(h.files["T.TXT"]) != "x\ny\n" {
		t.Fatalf("tee = out %q file %q st %d", out, h.files["T.TXT"], st)
	}
	// -a appends to what is already there.
	h.files["T.TXT"] = []byte("old\n")
	out, st = toolOut(t, h, "printf 'n\\n' | tee -a T.TXT")
	if st != 0 || string(h.files["T.TXT"]) != "old\nn\n" {
		t.Fatalf("tee -a = %q", h.files["T.TXT"])
	}
	// Replace mode truncates.
	_, _ = toolOut(t, h, "printf 'n\\n' | tee T.TXT")
	if string(h.files["T.TXT"]) != "n\n" {
		t.Fatalf("tee replace = %q", h.files["T.TXT"])
	}
	// Bare `tee F` must not truncate — unbound stdin refuses.
	out, st = toolOut(t, h, "tee T.TXT")
	if st != 2 || out != "gosh: tee: no input (pipe or redirect into tee)\n" {
		t.Fatalf("unbound tee = %q (st %d)", out, st)
	}
	// A failing file does not stop the rest.
	h.writeErrPaths = map[string]bool{"BAD.TXT": true}
	out, st = toolOut(t, h, "printf 'd\\n' | tee BAD.TXT GOOD.TXT")
	if st != 1 || out != "d\ngosh: tee: BAD.TXT: write failed\n" {
		t.Fatalf("tee partial = %q (st %d)", out, st)
	}
	if string(h.files["GOOD.TXT"]) != "d\n" {
		t.Fatalf("tee continued file = %q", h.files["GOOD.TXT"])
	}
	// A fifth FILE is the bound.
	_, st = toolOut(t, h, "printf 'x\\n' | tee a b c d e")
	if st != 2 {
		t.Fatalf("tee 5 files st = %d", st)
	}
}

func TestToolXargsInProcess(t *testing.T) {
	h := newFakeHost()
	out, st := toolOut(t, h, "printf 'a\\nb\\n' | xargs echo")
	if st != 0 || out != "a b\n" {
		t.Fatalf("xargs echo = (%q, %d)", out, st)
	}
	out, _ = toolOut(t, h, "printf 'a\\nb\\n' | xargs -n 1 echo pre")
	if out != "pre a\npre b\n" {
		t.Fatalf("xargs -n 1 = %q", out)
	}
	// One line is one item — spaces inside are literal (not POSIX).
	out, _ = toolOut(t, h, "printf 'one two\\nthree\\n' | xargs -n 1 echo")
	if out != "one two\nthree\n" {
		t.Fatalf("space item = %q", out)
	}
	// Items are literal: no globbing, no variable expansion.
	out, _ = toolOut(t, h, "printf '*.TXT\\n' | xargs echo")
	if out != "*.TXT\n" {
		t.Fatalf("literal item = %q", out)
	}
	// Output stays visible to a redirect.
	out, st = toolOut(t, h, "printf 'a\\nb\\n' | xargs -n 1 echo > X.OUT")
	if st != 0 || string(h.files["X.OUT"]) != "a\nb\n" {
		t.Fatalf("xargs > F = %q", h.files["X.OUT"])
	}
	// A function runs in-process too.
	h2 := newFakeHost()
	sh := NewShell(h2, &History{})
	sh.RunLine("fn rec() { echo \"R:$1 $2\" }")
	h2.out = nil
	st, _ = sh.RunLine("printf 'a\\n' | xargs rec P")
	if st != 0 || h2.outString() != "R:P a\n" {
		t.Fatalf("xargs fn = %q (st %d)", h2.outString(), st)
	}
	// Statuses: a failing invocation -> 123; a missing command -> 127.
	_, st = toolOut(t, h, "printf 'a\\nb\\n' | xargs false")
	if st != 123 {
		t.Fatalf("xargs 123 = %d", st)
	}
	h.missing["MISSING"] = true
	out, st = toolOut(t, h, "printf 'a\\n' | xargs MISSING")
	if st != 127 || !strings.Contains(out, "not found") {
		t.Fatalf("xargs 127 = (%q, %d)", out, st)
	}
	// Empty or unbound stdin runs nothing and exits 0.
	out, st = toolOut(t, h, "printf '' | xargs echo never")
	if st != 0 || out != "" {
		t.Fatalf("xargs empty = (%q, %d)", out, st)
	}
	_, st = toolOut(t, h, "xargs echo never")
	if st != 0 {
		t.Fatalf("xargs unbound st = %d", st)
	}
}

func TestToolXargsBounds(t *testing.T) {
	h := newFakeHost()
	// The 16-invocation cap refuses before anything runs.
	items := strings.Repeat("i\n", 17)
	h.files["IN.TXT"] = []byte(items)
	out, st := toolOut(t, h, "xargs -n 1 echo < IN.TXT")
	if st != 2 || !strings.Contains(out, "16 invocations") {
		t.Fatalf("xargs cap = %q (st %d)", out, st)
	}
	// An item past the 255-byte argv slot refuses before running.
	h.files["BIG.TXT"] = []byte(strings.Repeat("x", 256) + "\n")
	out, st = toolOut(t, h, "xargs APP < BIG.TXT")
	if st != 2 || !strings.Contains(out, "255") {
		t.Fatalf("xargs long item = %q (st %d)", out, st)
	}
	if len(h.externArgs) != 0 {
		t.Fatalf("long item still ran: %v", h.externArgs)
	}
	// External chunking: the argv cap is 8 slots minus the fixed args.
	h.files["MANY.TXT"] = []byte("i1\ni2\ni3\ni4\n")
	h.released = 0 // the fake's externals exit cleanly
	out, st = toolOut(t, h, "xargs APP a b c d e f g < MANY.TXT")
	if st != 0 || len(h.externArgs) != 4 {
		t.Fatalf("argv-cap chunks = %v (st %d)", h.externArgs, st)
	}
	for i, call := range h.externArgs {
		// argv[0] recorded is the name; 7 fixed + 1 item per invocation.
		if len(call) != 9 || call[0] != "APP" || call[len(call)-1] != "i"+string(rune('1'+i)) {
			t.Fatalf("call %d = %v", i, call)
		}
	}
	// An external under a redirect or $(...) cannot be captured. Under
	// `>` the refusal itself is stdout, so it lands in the file.
	h.files["IN.TXT"] = []byte("a\n")
	out, st = toolOut(t, h, "xargs APP > X.OUT < IN.TXT")
	if st != 1 || string(h.files["X.OUT"]) != "gosh: xargs: cannot capture an external app's output\n" {
		t.Fatalf("xargs capture > = %q file %q (st %d)", out, h.files["X.OUT"], st)
	}
	// Under $(...) the refusal message's own `'` makes the splice
	// unparseable (substitution output is re-tokenized — a pre-existing
	// limit); the observable is that the external never ran.
	h.externArgs = nil
	_, _ = toolOut(t, h, "x=$(printf 'a\\n' | xargs APP)")
	if len(h.externArgs) != 0 {
		t.Fatalf("xargs $(...) still ran the external: %v", h.externArgs)
	}
}

func TestToolTr(t *testing.T) {
	h := newFakeHost()
	out, st := toolOut(t, h, "printf 'abc\\n' | tr a-z A-Z")
	if st != 0 || out != "ABC\n" {
		t.Fatalf("tr range = (%q, %d)", out, st)
	}
	// SET2 pads with its last byte.
	out, _ = toolOut(t, h, "printf 'abc\\n' | tr abcd X")
	if out != "XXX\n" {
		t.Fatalf("tr pad = %q", out)
	}
	// -d deletes the SET1 bytes; escapes work inside sets.
	out, _ = toolOut(t, h, "printf 'banana\\n' | tr -d an")
	if out != "b\n" {
		t.Fatalf("tr -d = %q", out)
	}
	out, _ = toolOut(t, h, "printf 'a\\tb\\n' | tr '\\t' ' '")
	if out != "a b\n" {
		t.Fatalf("tr escape = %q", out)
	}
	// [:class:] refuses rather than mis-map.
	out, st = toolOut(t, h, "printf 'a\\n' | tr '[:lower:]' X")
	if st != 2 || !strings.Contains(out, "not supported") {
		t.Fatalf("tr [: = %q (st %d)", out, st)
	}
	// Redirect in/out is ordinary stdin wiring.
	h.files["IN.TXT"] = []byte("abc\n")
	out, st = toolOut(t, h, "tr a-z A-Z < IN.TXT > OUT.TXT")
	if st != 0 || string(h.files["OUT.TXT"]) != "ABC\n" {
		t.Fatalf("tr <> = %q (st %d)", h.files["OUT.TXT"], st)
	}
	// A descending range and a bad escape are usage errors.
	_, st = toolOut(t, h, "printf 'a\\n' | tr z-a X")
	if st != 2 {
		t.Fatalf("tr descending st = %d", st)
	}
	_, st = toolOut(t, h, "printf 'a\\n' | tr 'a\\q' X")
	if st != 2 {
		t.Fatalf("tr bad escape st = %d", st)
	}
}

func TestToolBaseDir(t *testing.T) {
	h := newFakeHost()
	cases := []struct{ line, want string }{
		{"basename /a/b/", "b\n"},
		{"basename /", "/\n"},
		{"basename X.TXT .TXT", "X\n"},
		{"basename b b", "b\n"},
		{"dirname a", ".\n"},
		{"dirname /a", "/\n"},
		{"dirname a/b/", "a\n"},
		{"dirname a/b/c", "a/b\n"},
		{"dirname /", "/\n"},
	}
	for _, tc := range cases {
		out, st := toolOut(t, h, tc.line)
		if st != 0 || out != tc.want {
			t.Fatalf("%q = (%q, %d), want %q", tc.line, out, st, tc.want)
		}
	}
	// Usage errors are status 2.
	if _, st := toolOut(t, h, "basename"); st != 2 {
		t.Fatalf("basename no-arg st = %d", st)
	}
	if _, st := toolOut(t, h, "dirname a b"); st != 2 {
		t.Fatalf("dirname two-arg st = %d", st)
	}
}
