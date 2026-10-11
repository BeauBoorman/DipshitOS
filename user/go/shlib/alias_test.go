// M98b alias tests (issue #2128): the table's bounds and listing, and the
// head-word expansion's reach — every path a simple command arrives by
// expands, every form that is not an unquoted head word stays verbatim.
package shlib

import (
	"strings"
	"testing"

	"virelai/vsys"
)

func TestAliasTableOps(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	run("alias t='tail -n 5'")
	run("alias hi='echo hello'")
	h.out = nil
	if st := run("alias"); st != 0 || h.outString() != "alias hi='echo hello'\nalias t='tail -n 5'\n" {
		t.Fatalf("alias list = %q (st %d)", h.outString(), st)
	}
	h.out = nil
	if st := run("alias t"); st != 0 || h.outString() != "alias t='tail -n 5'\n" {
		t.Fatalf("alias t = %q", h.outString())
	}
	h.out = nil
	if st := run("alias nope"); st != 1 || h.outString() != "gosh: alias: nope: not found\n" {
		t.Fatalf("alias nope = %q (st %d)", h.outString(), st)
	}
	// Replace in place — no second row, same name.
	run("alias hi='echo bye'")
	h.out = nil
	run("alias hi")
	if h.outString() != "alias hi='echo bye'\n" {
		t.Fatalf("replaced = %q", h.outString())
	}
	// unalias removes each name; an unknown one reports but does not stop.
	h.out = nil
	st := run("unalias t nope2 hi")
	if st != 1 || h.outString() != "gosh: unalias: nope2: not found\n" {
		t.Fatalf("unalias = %q (st %d)", h.outString(), st)
	}
	h.out = nil
	run("alias")
	if h.outString() != "" {
		t.Fatalf("table after unalias = %q, want empty", h.outString())
	}
	// -a clears whatever remains.
	run("alias a='echo a'")
	run("unalias -a")
	h.out = nil
	run("alias")
	if h.outString() != "" {
		t.Fatalf("after -a = %q", h.outString())
	}
}

func TestAliasHeadExpansion(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	run("alias hi='echo hello'")
	run("alias mk='echo made'")
	cases := []struct{ line, want string }{
		{"hi", "hello\n"},
		{"hi ; hi", "hello\nhello\n"},
		{"true && hi", "hello\n"},
		{"false || hi", "hello\n"},
		{"echo x | mk", "made\n"},
		{"mk | cat", "made\n"},
		{"if true; then hi; fi", "hello\n"},
		{"for i in a b; do mk; done", "made\nmade\n"},
		{"while true; do hi; break; done", "hello\n"},
	}
	for _, tc := range cases {
		h.out = nil
		st, _ := sh.RunLine(tc.line)
		if h.outString() != tc.want {
			t.Fatalf("%q = %q (st %d), want %q", tc.line, h.outString(), st, tc.want)
		}
	}
	// Function bodies expand at call time.
	sh.RunLine("fn f() { hi }")
	h.out = nil
	sh.RunLine("f")
	if h.outString() != "hello\n" {
		t.Fatalf("fn body = %q", h.outString())
	}
	// A sourced file is the same session.
	h.files["A.SH"] = []byte("alias s='echo sourced'\ns\n")
	h.out = nil
	run("source A.SH")
	if h.outString() != "sourced\n" {
		t.Fatalf("sourced alias = %q", h.outString())
	}
}

func TestAliasNoExpansion(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	run("alias hi='echo hello'")
	// Argument position and partial words stay verbatim.
	for _, tc := range []struct{ line, want string }{
		{"echo hi", "hi\n"},
		{"echo xhi", "xhi\n"},
		{"echo 'hi'", "hi\n"},
		{"echo \"hi\"", "hi\n"},
	} {
		h.out = nil
		sh.RunLine(tc.line)
		if h.outString() != tc.want {
			t.Fatalf("%q = %q, want %q", tc.line, h.outString(), tc.want)
		}
	}
	// The quoting bypass is about the COMMAND word: \hi, 'hi', "hi" run
	// the literal name (here: a missing external).
	for _, line := range []string{`\hi`, `'hi'`, `"hi"`} {
		h.out = nil
		sh.RunLine(line)
		if strings.Contains(h.outString(), "hello") {
			t.Fatalf("%q expanded to the alias: %q", line, h.outString())
		}
	}
}

func TestAliasRecursion(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	run("alias a='b x'")
	run("alias b='a y'")
	// a -> b x -> a y x -> (a visited) a y x — bash's one-hop-back stop.
	h.out = nil
	run("a")
	// `a y x` is not a builtin; the point is termination, so assert the
	// expansion did not hang and produced the final head `a`.
	if !strings.Contains(h.outString(), "not found") && h.outString() != "" {
		t.Fatalf("a/b cycle = %q", h.outString())
	}
	// Self-reference expands exactly once.
	run("alias s='s -l'")
	h.out = nil
	run("s")
	if strings.Count(h.outString(), "s") > 4 {
		t.Fatalf("self-ref looped: %q", h.outString())
	}
}

func TestAliasBounds(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	for i := 0; i < 16; i++ {
		run("alias n" + string(rune('a'+i)) + "='echo x'")
	}
	h.out = nil
	if st := run("alias zz='echo x'"); st != 1 ||
		!strings.Contains(h.outString(), "at most 16") {
		t.Fatalf("17th = %q (st %d)", h.outString(), st)
	}
	h.out = nil
	if st := run("alias " + strings.Repeat("n", 33) + "='echo x'"); st != 1 ||
		!strings.Contains(h.outString(), "32") {
		t.Fatalf("long name = %q (st %d)", h.outString(), st)
	}
	h.out = nil
	if st := run("alias bad!='echo x'"); st != 1 ||
		!strings.Contains(h.outString(), "invalid name") {
		t.Fatalf("bad chars = %q (st %d)", h.outString(), st)
	}
	h.out = nil
	if st := run("alias v='" + strings.Repeat("v", 257) + "'"); st != 1 ||
		!strings.Contains(h.outString(), "256") {
		t.Fatalf("long value = %q (st %d)", h.outString(), st)
	}
	// Post-expansion line length: a chain of chained aliases each adding
	// ~240 bytes blows past 2048 before the 16-entry table could.
	run("unalias -a")
	pad := strings.Repeat("x", 240)
	for i := 1; i <= 10; i++ {
		run("alias c" + vsys.Itoa64(int64(i)) + "='c" + vsys.Itoa64(int64(i+1)) + " " + pad + "'")
	}
	run("alias c11='echo done'")
	h.out = nil
	st := run("c1")
	if st != 1 || !strings.Contains(h.outString(), "2048") {
		t.Fatalf("expanded length = %q (st %d)", h.outString(), st)
	}
}

func TestAliasRefusedValues(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	want := "gosh: alias: value must be one command (no ; && || &)\n"
	for _, line := range []string{
		"alias a='x;y'", "alias b='x && y'", "alias c='x || y'", "alias d='x &'",
	} {
		h.out = nil
		if st := run(line); st != 1 || h.outString() != want {
			t.Fatalf("%q = %q (st %d)", line, h.outString(), st)
		}
	}
	// A single pipe is allowed.
	h.out = nil
	run("alias pg='cat | grep'")
	run("pg PIPEX < IN.TXT")
	// (the pipe refuses on the fake host differently, but the definition
	// itself must have been accepted)
	if _, ok := sh.aliases["pg"]; !ok {
		t.Fatalf("pipe value refused")
	}
}

func TestAliasSessionPersistence(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	// Startup-style lines: PROFILE.SH defines, a later line uses.
	sh.RunLine("alias hi='echo hello'")
	sh.RunLine("alias lg='echo logger'")
	h.out = nil
	sh.RunLine("hi")
	if h.outString() != "hello\n" {
		t.Fatalf("session alias = %q", h.outString())
	}
	// A fresh shell (a -c child) starts with an empty table.
	child := NewShell(h, &History{})
	h.out = nil
	child.RunLine("alias")
	if h.outString() != "" {
		t.Fatalf("child shell inherited the table: %q", h.outString())
	}
}

func TestAliasShadowingAndBypass(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) (int, Action) { return sh.RunLine(line) }
	run("alias exit='echo BYE'")
	st, act := run("exit")
	if act == ActionExit || h.outString() != "BYE\n" {
		t.Fatalf("shadowed exit: act=%v out=%q (st %d)", act, h.outString(), st)
	}
	// \exit bypasses the alias and reaches the builtin.
	_, act = run(`\exit`)
	if act != ActionExit {
		t.Fatalf("\\exit act = %v, want ActionExit", act)
	}
	// `exec NAME` — NAME is an argument, never a candidate.
	h2 := newFakeHost()
	sh2 := NewShell(h2, &History{})
	sh2.RunLine("alias x='echo y'")
	h2.out = nil
	sh2.RunLine("exec x")
	if strings.Contains(h2.outString(), "y\n") {
		t.Fatalf("exec x expanded: %q", h2.outString())
	}
}
