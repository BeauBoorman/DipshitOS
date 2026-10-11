// M98a glob expansion tests (issue #2127): a canned per-directory lister
// stands in for the slot-79 seam, so every case is pure engine behavior —
// which words glob, which stay literal, and where the listing is asked for.
package shlib

import (
	"fmt"
	"strings"
	"testing"

	"virelai/vi"
)

// globHost is fakeHost plus the path-aware listing glob expansion needs.
// dirs keys are canonical /-rooted paths (what the engine resolves PWD
// into), errs injects listing failures (vi.ErrTreeLimit for the named
// refusal, any other error for "no match"), calls records the order the
// listing was asked for.
type globHost struct {
	fakeHost
	dirs  map[string][]vi.DirItem
	errs  map[string]error
	calls []string
}

func newGlobHost() *globHost {
	h := &globHost{
		dirs: map[string][]vi.DirItem{},
		errs: map[string]error{},
	}
	h.fakeHost = *newFakeHost()
	return h
}

func (g *globHost) ListPath(dir string) ([]vi.DirItem, error) {
	g.calls = append(g.calls, dir)
	if err, ok := g.errs[dir]; ok {
		return nil, err
	}
	return g.dirs[dir], nil
}

func files(names ...string) []vi.DirItem {
	out := make([]vi.DirItem, len(names))
	for i, n := range names {
		out[i] = vi.DirItem{Name: n}
	}
	return out
}

func newGlobShell(h *globHost) *Shell {
	return NewShell(h, &History{})
}

func TestGlobStarBasics(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files("B.TXT", "A.TXT", "RUN.SH", ".HIDDEN.TXT", "SUB")
	h.dirs["/SUB"] = files()
	sh := newGlobShell(h)
	st, _ := sh.RunLine("echo *.TXT")
	if st != 0 || h.outString() != "A.TXT B.TXT\n" {
		t.Fatalf("*.TXT = %q (st %d), want sorted A.TXT B.TXT", h.outString(), st)
	}
	if len(h.calls) != 1 || h.calls[0] != "/" {
		t.Fatalf("list calls = %v, want [/]", h.calls)
	}
}

func TestGlobMetacharacters(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files("A1", "AB", "ABC", "A2.TXT", "B1.TXT", "C9.TXT", "D0", "aa")
	sh := newGlobShell(h)
	cases := []struct{ line, want string }{
		{"echo A?", "A1 AB\n"},
		{"echo [AB]*", "A1 A2.TXT AB ABC B1.TXT\n"},
		{"echo [a-c]*", "aa\n"},
		{"echo [!a]*", "A1 A2.TXT AB ABC B1.TXT C9.TXT D0\n"},
		{"echo [^a]*", "A1 A2.TXT AB ABC B1.TXT C9.TXT D0\n"},
		{"echo [a-c]?", "aa\n"},
	}
	for _, tc := range cases {
		h.out = nil
		st, _ := sh.RunLine(tc.line)
		if st != 0 || h.outString() != tc.want {
			t.Fatalf("%q = %q (st %d), want %q", tc.line, h.outString(), st, tc.want)
		}
	}
}

func TestGlobLeadingDot(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files(".ENV", "A.TXT", ".TXT")
	sh := newGlobShell(h)
	st, _ := sh.RunLine("echo *")
	if h.outString() != "A.TXT\n" || st != 0 {
		t.Fatalf("* = %q, want hidden names skipped", h.outString())
	}
	h.out = nil
	sh.RunLine("echo .?*")
	if h.outString() != ".ENV .TXT\n" {
		t.Fatalf(".?* = %q, want both 2+-char dot names", h.outString())
	}
	h.out = nil
	sh.RunLine("echo .*")
	if h.outString() != ".ENV .TXT\n" {
		t.Fatalf(".* = %q, want both dot names", h.outString())
	}
}

func TestGlobPwdRelative(t *testing.T) {
	h := newGlobHost()
	h.dirs["/data"] = files("ONE.TXT", "TWO.TXT")
	h.dirs["/data/docs"] = files("D1.TXT", "D2.TXT")
	h.dirs["/x"] = files("TOP.TXT")
	h.dirs["/"] = files()
	sh := newGlobShell(h)
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	run("cd data")
	h.out = nil
	run("echo *.TXT")
	if h.outString() != "ONE.TXT TWO.TXT\n" {
		t.Fatalf("PWD glob = %q, want data's names", h.outString())
	}
	if got := h.calls[len(h.calls)-1]; got != "/data" {
		t.Fatalf("listed %q, want /data", got)
	}
	h.out = nil
	run("echo docs/*.TXT")
	if h.outString() != "docs/D1.TXT docs/D2.TXT\n" {
		t.Fatalf("docs/*.TXT = %q", h.outString())
	}
	if got := h.calls[len(h.calls)-1]; got != "/data/docs" {
		t.Fatalf("listed %q, want /data/docs", got)
	}
	h.out = nil
	run("echo /x/*.TXT")
	if h.outString() != "/x/TOP.TXT\n" {
		t.Fatalf("absolute glob = %q", h.outString())
	}
}

func TestGlobLiteralForms(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files("A.TXT", "B.TXT")
	sh := newGlobShell(h)
	cases := []struct{ line, want string }{
		{"echo '*.TXT'", "*.TXT\n"},
		{"echo \"*.TXT\"", "*.TXT\n"},
		{"echo \\*.TXT", "*.TXT\n"},
		{"echo A\"*\".TXT", "A*.TXT\n"},
		{"echo *.NOPE", "*.NOPE\n"},
		{"echo */X", "*/X\n"},
		{"echo empty/*", "empty/*\n"},
		{"echo [*", "[*\n"},
	}
	h.dirs["/empty"] = files()
	for _, tc := range cases {
		h.out = nil
		h.calls = nil
		st, _ := sh.RunLine(tc.line)
		if st != 0 || h.outString() != tc.want {
			t.Fatalf("%q = %q (st %d), want %q", tc.line, h.outString(), st, tc.want)
		}
	}
}

func TestGlobVariableBytesLiteral(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files("A.TXT", "B.TXT", "XA.TXT", "XB.TXT")
	sh := newGlobShell(h)
	run := func(line string) { sh.RunLine(line) }
	run("set V=*")
	h.out = nil
	run("echo $V")
	if h.outString() != "*\n" {
		t.Fatalf("$V = %q, want literal *", h.outString())
	}
	// The variable's bytes are literal; the TYPED `*` still globs.
	h.out = nil
	run("set V=A")
	run("echo X$V*.TXT")
	if h.outString() != "XA.TXT\n" {
		t.Fatalf("X$V*.TXT = %q, want XA.TXT", h.outString())
	}
	// set's NAME=VALUE words are exempt from globbing entirely.
	h.out = nil
	run("set P=*.TXT")
	run("echo got:$P")
	if h.outString() != "got:*.TXT\n" {
		t.Fatalf("set P=*.TXT stored %q", h.outString())
	}
}

func TestGlobCommandSubstNeverReglobs(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files("A.TXT", "B.TXT")
	sh := newGlobShell(h)
	cases := []struct{ line, want string }{
		{"echo $(echo '*.TXT')", "*.TXT\n"},
		{"echo $(echo '*.TXT'); echo done", "*.TXT\ndone\n"},
		{"echo ok && echo $(echo '*.TXT')", "ok\n*.TXT\n"},
		{"echo $(echo docs/*.TXT)", "docs/*.TXT\n"},
	}
	for _, tc := range cases {
		h.out = nil
		st, _ := sh.RunLine(tc.line)
		if h.outString() != tc.want {
			t.Fatalf("%q = %q (st %d), want %q", tc.line, h.outString(), st, tc.want)
		}
	}
	// Inside a function body — the def stores raw text, so the splice
	// happens when `f` runs and its marks must survive that hop.
	sh.RunLine("fn f() { echo $(echo '*.TXT') }")
	h.out = nil
	sh.RunLine("f")
	if h.outString() != "*.TXT\n" {
		t.Fatalf("fn-body substitution = %q, want literal *.TXT", h.outString())
	}
	// And inside an if-condition — the recursion point that used to
	// strip the literal marks before the segment ever ran.
	h.out = nil
	sh.RunLine("if test -e $(echo 'NOPE.*'); then echo HIT; fi")
	if h.outString() != "" {
		t.Fatalf("if-cond substitution reglobbed: %q", h.outString())
	}
	// With NOPE.1 present, the same line must NOT hit: a leaked glob
	// would expand to NOPE.1 and test true; literal `NOPE.*` misses.
	// (Files sit at the root, where resolvePath passes the typed name
	// through verbatim — hence the bare keys.)
	h.out = nil
	h.files["NOPE.1"] = []byte("x")
	sh.RunLine("if test -e $(echo 'NOPE.*'); then echo HIT; fi")
	if h.outString() != "" {
		t.Fatalf("substituted NOPE.* globbed to NOPE.1: %q", h.outString())
	}
	// And a file literally named `NOPE.*` resolves, proving the bytes
	// arrived intact.
	h.files["NOPE.*"] = []byte("x")
	sh.RunLine("if test -e $(echo 'NOPE.*'); then echo HIT; fi")
	if h.outString() != "HIT\n" {
		t.Fatalf("if-cond literal = %q, want HIT", h.outString())
	}
}

func TestGlobCommandWordAndRedirectsStayLiteral(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files("A.TXT", "B.TXT", "GOSH.ELF")
	sh := newGlobShell(h)
	// The command word itself never globs — `*.ELF` is a program name.
	h.missing["*.ELF"] = true
	st, _ := sh.RunLine("*.ELF")
	if st == 0 {
		t.Fatalf("*.ELF ran something")
	}
	if !strings.Contains(h.outString(), "not found") {
		t.Fatalf("*.ELF message = %q", h.outString())
	}
	// Redirect targets stay literal: > *.OUT writes a file named `*.OUT`.
	h.out = nil
	sh.RunLine("echo hi > *.OUT")
	if _, ok := h.files["*.OUT"]; !ok {
		t.Fatalf("redirect target globbed; files = %v", h.files)
	}
	// Input redirects too.
	h.out = nil
	sh.RunLine("cat < *.TXT")
	if !strings.Contains(h.outString(), "not found") {
		t.Fatalf("< globbed; out = %q", h.outString())
	}
}

func TestGlobCaseUnchanged(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files("A.TXT", "B.TXT")
	sh := newGlobShell(h)
	st, _ := sh.RunLine("case A.TXT in *.TXT) echo hit;; *.SH) echo miss;; esac")
	if st != 0 || h.outString() != "hit\n" {
		t.Fatalf("case = %q (st %d), want hit", h.outString(), st)
	}
	// The subject stays a word, not a listing: `*.TXT` as subject matches
	// the `*.TXT` arm as literal text — and no directory was consulted.
	h.out = nil
	h.calls = nil
	sh.RunLine("case *.TXT in *.TXT) echo hit;; *) echo miss;; esac")
	if h.outString() != "hit\n" {
		t.Fatalf("unquoted subject = %q, want hit", h.outString())
	}
	if len(h.calls) != 0 {
		t.Fatalf("case touched the listing: %v", h.calls)
	}
}

func TestGlobForList(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files("B.SH", "A.SH", "C.TXT")
	sh := newGlobShell(h)
	st, _ := sh.RunLine("for f in *.SH; do echo got:$f; done")
	if st != 0 || h.outString() != "got:A.SH\ngot:B.SH\n" {
		t.Fatalf("for *.SH = %q (st %d)", h.outString(), st)
	}
	// A no-match for word stays literal, exactly like a plain word.
	h.out = nil
	sh.RunLine("for f in *.NOPE; do echo got:$f; done")
	if h.outString() != "got:*.NOPE\n" {
		t.Fatalf("for no-match = %q", h.outString())
	}
}

func TestGlobForListBound(t *testing.T) {
	h := newGlobHost()
	var names []string
	for i := 0; i < 17; i++ {
		names = append(names, fmt.Sprintf("S%02d.SH", i))
	}
	h.dirs["/"] = files(names...)
	sh := newGlobShell(h)
	st, _ := sh.RunLine("for f in *.SH; do echo got:$f; done")
	if st != 2 {
		t.Fatalf("for >16 matches st = %d, want 2", st)
	}
	if !strings.Contains(h.outString(), "for word list too long (at most 16 words)") {
		t.Fatalf("bound message = %q", h.outString())
	}
	if strings.Contains(h.outString(), "got:") {
		t.Fatalf("refused loop still ran: %q", h.outString())
	}
}

func TestGlobTreeLimitRefusal(t *testing.T) {
	h := newGlobHost()
	h.errs["/data"] = vi.ErrTreeLimit
	sh := newGlobShell(h)
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	run("cd data")
	h.out = nil
	st := run("echo *.TXT")
	if st != 1 {
		t.Fatalf("treelimit st = %d, want 1", st)
	}
	if got := h.outString(); got != "gosh: glob: /data: more than 256 entries\n" {
		t.Fatalf("treelimit message = %q", got)
	}
}

func TestGlobTestAndBracketTool(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files("REAL.TXT")
	sh := newGlobShell(h)
	// `test`'s [ ] form and ! operator keep working: the bracket words are
	// not glob patterns (a `[` with no closing `]` is literal anyway) and
	// the test syntax itself must never consult a directory.
	st, _ := sh.RunLine("[ a = a ]")
	if st != 0 {
		t.Fatalf("[ a = a ] st = %d", st)
	}
	st, _ = sh.RunLine("test ! X")
	if st != 1 {
		t.Fatalf("test ! X st = %d, want 1 (nonempty)", st)
	}
	if len(h.calls) != 0 {
		t.Fatalf("test syntax listed a directory: %v", h.calls)
	}
	// A no-match pattern stays literal, so `-e` probes `*.NOPE` itself
	// (the `!` form is unary-only in this test subset).
	st, _ = sh.RunLine("test -e *.NOPE")
	if st != 1 {
		t.Fatalf("test -e *.NOPE st = %d, want 1 (literal miss)", st)
	}
	// A matching pattern expands before test sees the name.
	h.files["REAL.TXT"] = []byte("x")
	st, _ = sh.RunLine("test -e *.TXT")
	if st != 0 {
		t.Fatalf("test -e *.TXT st = %d, want globbed to REAL.TXT", st)
	}
}

func TestGlobWithoutListerStaysLiteral(t *testing.T) {
	// fakeHost has no ListPath: a host without the optional capability
	// leaves glob words literal, the pre-M98a behavior.
	h := newFakeHost()
	sh := NewShell(h, &History{})
	st, _ := sh.RunLine("echo *.TXT")
	if st != 0 || h.outString() != "*.TXT\n" {
		t.Fatalf("no lister = %q (st %d)", h.outString(), st)
	}
}
