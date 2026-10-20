// Tests for the M19 scripting slice (#1450 slice 4): the pure parser in
// control.go and the engine paths it drives. The parser cases mirror the
// tests in user/src/lib/script.zig case for case, so a retargeted gate is
// asserting semantics that were already pinned in the reference.
package shlib

import (
	"strconv"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Chains
// ---------------------------------------------------------------------------

func TestChainSplit(t *testing.T) {
	segs, ops, too := chainSplit("echo a && echo b")
	if too || len(segs) != 2 || len(ops) != 1 {
		t.Fatalf("split = %q/%v too=%v", segs, ops, too)
	}
	if ops[0] != opAnd || segs[0] != "echo a" || segs[1] != "echo b" {
		t.Fatalf("segs=%q ops=%v", segs, ops)
	}
	segs, ops, too = chainSplit("false || echo ok; echo done")
	if too || len(segs) != 3 {
		t.Fatalf("three segments: %q too=%v", segs, too)
	}
	if ops[0] != opOr || ops[1] != opSeq || segs[2] != "echo done" {
		t.Fatalf("ops=%v segs=%q", ops, segs)
	}
	// No operator at all: one segment, no ops, so the caller runs it directly.
	if _, ops, too = chainSplit("echo plain"); too || len(ops) != 0 {
		t.Fatalf("plain line produced ops %v too=%v", ops, too)
	}
	// Quoted and escaped operators are literal.
	if _, ops, _ = chainSplit("echo 'a && b'"); len(ops) != 0 {
		t.Fatalf("single-quoted operator split: %v", ops)
	}
	if _, ops, _ = chainSplit(`echo "a || b"`); len(ops) != 0 {
		t.Fatalf("double-quoted operator split: %v", ops)
	}
	if _, ops, _ = chainSplit(`echo a \; b`); len(ops) != 0 {
		t.Fatalf("escaped operator split: %v", ops)
	}
	// Bounded: chainMax segments, anything longer is refused not truncated.
	if _, _, too = chainSplit("a;b;c;d"); too {
		t.Fatal("four segments must be allowed")
	}
	if _, _, too = chainSplit("a;b;c;d;e"); !too {
		t.Fatal("five segments must be refused")
	}
}

// TestChainSplitTracksQuotesSeparately is the one place this scanner
// deliberately differs from script.zig: the reference toggled both quote
// flags on any quote byte, so an apostrophe inside a double-quoted word ended
// chain splitting for the rest of the line.
func TestChainSplitTracksQuotesSeparately(t *testing.T) {
	segs, ops, too := chainSplit(`echo "it's here" && echo after`)
	if too || len(segs) != 2 || len(ops) != 1 || ops[0] != opAnd {
		t.Fatalf("apostrophe in a double-quoted word broke the chain: %q %v", segs, ops)
	}
}

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

func TestEvalArith(t *testing.T) {
	cases := []struct {
		expr string
		want int64
	}{
		{"1+2*3", 7}, {"(1+2)*3", 9}, {"(2+3)*4", 20}, {"10/2", 5},
		{"10%3", 1}, {"-2*3", -6}, {"5/0", 0}, {"7%0", 0}, {"+3", 3},
		{"2*(3+4)-5", 9},
	}
	for _, c := range cases {
		if got := evalArith(c.expr); got != c.want {
			t.Errorf("evalArith(%q) = %d, want %d", c.expr, got, c.want)
		}
	}
}

func TestArithExpand(t *testing.T) {
	cases := []struct{ in, want string }{
		{"X=$(( (2+3)*4 ))", "X=20"},
		{"a$((3+4))b", "a7b"},
		{"plain", "plain"},
		{"$((broken", "$((broken"}, // incomplete: unchanged, never a panic
		{"set X=$(( 1 + 1 ))", "set X=2"},
	}
	for _, c := range cases {
		if got := arithExpand(c.in); got != c.want {
			t.Errorf("arithExpand(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// ---------------------------------------------------------------------------
// Command substitution
// ---------------------------------------------------------------------------

func TestLocateCommandSubst(t *testing.T) {
	c, ok := locateCommandSubst("echo SUB=$(echo inner)")
	if !ok || c.prefix != "echo SUB=" || c.inner != "echo inner" || c.suffix != "" {
		t.Fatalf("located %+v ok=%v", c, ok)
	}
	if _, ok := locateCommandSubst("no subst"); ok {
		t.Fatal("a line with no substitution reported one")
	}
	if _, ok := locateCommandSubst("a$(b$(c))d"); ok {
		t.Fatal("nested substitution must be refused, not guessed")
	}
	if _, ok := locateCommandSubst("a$(unclosed"); ok {
		t.Fatal("unclosed substitution must be refused")
	}
	// `$((...))` is arithmetic, not substitution.
	if _, ok := locateCommandSubst("echo $((1+2))"); ok {
		t.Fatal("arithmetic was read as command substitution")
	}
	mixed, ok := locateCommandSubst("echo $((1)) $(pwd)")
	if !ok || mixed.inner != "pwd" || mixed.prefix != "echo $((1)) " {
		t.Fatalf("mixed arithmetic/substitution: %+v ok=%v", mixed, ok)
	}
}

// ---------------------------------------------------------------------------
// Constructs
// ---------------------------------------------------------------------------

func TestFindKeywordIsWholeWord(t *testing.T) {
	// `fi` inside `fixture` is not the keyword.
	if _, ok := findKeyword("fixture fi", "fi"); !ok {
		t.Fatal("trailing whole-word keyword not found")
	}
	if at, _ := findKeyword("fixture fi", "fi"); at != 8 {
		t.Fatalf("keyword matched inside a word at %d", at)
	}
	if _, ok := findKeyword("fixture", "fi"); ok {
		t.Fatal("keyword matched inside a longer word")
	}
}

func TestParseIf(t *testing.T) {
	st, ok := parseIf("if true; then echo yes; else echo no; fi")
	if !ok || st.cond != "true" || st.thenBody != "echo yes" || !st.hasElse || st.elseBody != "echo no" {
		t.Fatalf("parse = %+v ok=%v", st, ok)
	}
	st, ok = parseIf("if false; then echo only; fi")
	if !ok || st.hasElse || st.thenBody != "echo only" {
		t.Fatalf("no-else parse = %+v ok=%v", st, ok)
	}
	if _, ok = parseIf("if true; echo missing fi"); ok {
		t.Fatal("missing fi must not parse")
	}
	if _, ok = parseIf("if true; then x"); ok {
		t.Fatal("missing fi must not parse")
	}
}

func TestParseFor(t *testing.T) {
	st, ok, tooMany := parseFor("for n in a b c; do echo ITEM-$n; done")
	if !ok || tooMany || st.varName != "n" || len(st.words) != 3 || st.words[0] != "a" || st.words[2] != "c" {
		t.Fatalf("parse = %+v ok=%v tooMany=%v", st, ok, tooMany)
	}
	if st.body != "echo ITEM-$n" {
		t.Fatalf("body = %q", st.body)
	}
	if _, ok, _ = parseFor("for n in a b; echo bad; done"); ok {
		t.Fatal("missing do must not parse")
	}
	// Past forWordMax the word list is REFUSED, not truncated: the reference
	// filled its [16] array and dropped the tail, silently running a
	// different loop than the one written.
	words := ""
	for i := 0; i < forWordMax; i++ {
		words += " w" + string(rune('a'+i))
	}
	if _, ok, tooMany = parseFor("for n in" + words + "; do echo x; done"); !ok || tooMany {
		t.Fatalf("at the bound: ok=%v tooMany=%v", ok, tooMany)
	}
	if _, _, tooMany = parseFor("for n in" + words + " one-more; do echo x; done"); !tooMany {
		t.Fatal("one word past forWordMax must report tooMany")
	}
}

func TestParseWhile(t *testing.T) {
	st, ok := parseWhile("while true; do echo tick; done")
	if !ok || st.cond != "true" || st.body != "echo tick" {
		t.Fatalf("parse = %+v ok=%v", st, ok)
	}
	if _, ok = parseWhile("while true; echo bad; done"); ok {
		t.Fatal("missing do must not parse")
	}
}

func TestSplitCommands(t *testing.T) {
	got, tooMany := splitCommands("  echo a ; echo b ;; echo c ")
	want := []string{"echo a", "echo b", "echo c"}
	if tooMany {
		t.Fatal("three commands must not report tooMany")
	}
	if len(got) != len(want) {
		t.Fatalf("split = %q", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("split[%d] = %q, want %q", i, got[i], want[i])
		}
	}
	if empty, _ := splitCommands("  ; ; "); len(empty) != 0 {
		t.Fatal("empty commands must be dropped")
	}
	// Past bodyCmdsMax the body is REFUSED, not truncated: the reference ran
	// its first 16 commands and dropped the rest without a word.
	body := ""
	for i := 0; i < bodyCmdsMax; i++ {
		if i > 0 {
			body += "; "
		}
		body += "echo c" + strconv.Itoa(i)
	}
	if at, tm := splitCommands(body); len(at) != bodyCmdsMax || tm {
		t.Fatalf("at the bound: %d commands tooMany=%v", len(at), tm)
	}
	if over, tm := splitCommands(body + "; echo one-more"); !tm {
		t.Fatalf("one command past bodyCmdsMax must report tooMany (got %d commands)", len(over))
	}
}

func TestParseFuncDef(t *testing.T) {
	def, ok := parseFuncDef("greet(name) { echo HELLO-$name; echo BYE }")
	if !ok || def.name != "greet" || len(def.argNames) != 1 || def.argNames[0] != "name" {
		t.Fatalf("def = %+v ok=%v", def, ok)
	}
	var tbl funcTable
	if !tbl.define(def) {
		t.Fatal("define failed")
	}
	f := tbl.find("greet")
	if f == nil || len(f.body) != 2 || f.body[1] != "echo BYE" {
		t.Fatalf("table entry = %+v", f)
	}
	// Redefinition replaces in place rather than adding a second entry.
	def2, _ := parseFuncDef("greet() { echo HI }")
	if !tbl.define(def2) {
		t.Fatal("redefine failed")
	}
	if len(tbl.funcs) != 1 || len(tbl.find("greet").argNames) != 0 {
		t.Fatalf("redefine left %d entries with %d args", len(tbl.funcs), len(tbl.find("greet").argNames))
	}
	if _, ok := parseFuncDef("bad"); ok {
		t.Fatal("a definition with no body must not parse")
	}
	// Bounded: past funcMax a NEW function is refused, a redefinition is not.
	var small funcTable
	for i := 0; i < funcMax; i++ {
		d, _ := parseFuncDef("f" + string(rune('a'+i)) + "() { echo x }")
		if !small.define(d) {
			t.Fatalf("define %d refused inside the bound", i)
		}
	}
	extra, _ := parseFuncDef("zlast() { echo x }")
	if small.define(extra) {
		t.Fatal("table grew past funcMax")
	}
}

func TestIsFuncDefLine(t *testing.T) {
	for _, line := range []string{"fn", "fn greet() { echo x }", "fn\tgreet() { echo x }"} {
		if !isFuncDefLine(line) {
			t.Errorf("isFuncDefLine(%q) = false", line)
		}
	}
	// `fnord` is a command, not a definition.
	if isFuncDefLine("fnord x") {
		t.Error("fnord read as a definition")
	}
}

func TestParseCaseAndMatch(t *testing.T) {
	st, ok, _ := parseCase("case $X in a) echo A;; b|c) echo BC;; *) echo OTHER;; esac")
	if !ok || st.subject != "$X" || len(st.arms) != 3 {
		t.Fatalf("parse = %+v ok=%v", st, ok)
	}
	if st.arms[1].pattern != "b|c" || st.arms[1].body != "echo BC" || st.arms[2].pattern != "*" {
		t.Fatalf("arms = %+v", st.arms)
	}
	for _, bad := range []string{"case x", "case in esac", "if x; then y; fi", "case x in esac"} {
		if _, ok, _ := parseCase(bad); ok {
			t.Errorf("malformed case parsed: %q", bad)
		}
	}
	// Past caseArmMax the arm list is REFUSED, not truncated: the reference
	// stopped filling its [8] array and ignored every later arm.
	arms := ""
	for i := 0; i < caseArmMax; i++ {
		arms += " p" + strconv.Itoa(i) + ") echo a;;"
	}
	if st, ok, tm := parseCase("case x in" + arms + " esac"); !ok || tm || len(st.arms) != caseArmMax {
		t.Fatalf("at the bound: arms=%d ok=%v tooMany=%v", len(st.arms), ok, tm)
	}
	if _, _, tm := parseCase("case x in" + arms + " one-more) echo a;; esac"); !tm {
		t.Fatal("one arm past caseArmMax must report tooMany")
	}
	matches := []struct {
		pat, subj string
		want      bool
	}{
		{"a", "a", true}, {"a", "b", false}, {"b|c", "c", true},
		{"*", "anything", true}, {"*.TXT", "NOTES.TXT", true},
		{"*.TXT", "NOTES.BIN", false}, {"beta", "beta", true},
	}
	for _, m := range matches {
		if got := caseMatch(m.pat, m.subj); got != m.want {
			t.Errorf("caseMatch(%q, %q) = %v, want %v", m.pat, m.subj, got, m.want)
		}
	}
}

func TestGlobMatch(t *testing.T) {
	cases := []struct {
		pat, name string
		want      bool
	}{
		{"*", "", true}, {"*", "abc", true}, {"a*", "abc", true},
		{"*c", "abc", true}, {"a?c", "abc", true}, {"a?c", "ac", false},
		{"abc", "abc", true}, {"abc", "abd", false},
		{"[ab]c", "ac", true}, {"[ab]c", "bc", true}, {"[ab]c", "cc", false},
		{"[a-c]1", "b1", true}, {"[!a]1", "b1", true}, {"[!a]1", "a1", false},
		{"[", "[", false}, // malformed class matches nothing (pipe.zig)
		{"*a*b*c", "xxaxxbxxc", true}, {"*a*b*c", "xxaxxc", false},
	}
	for _, c := range cases {
		if got := globMatch(c.pat, c.name); got != c.want {
			t.Errorf("globMatch(%q, %q) = %v, want %v", c.pat, c.name, got, c.want)
		}
	}
}

// ---------------------------------------------------------------------------
// Engine paths
// ---------------------------------------------------------------------------

func TestEngineArithmetic(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	run("set X=$(( (2+3)*4 ))")
	run("echo ARITH=$X")
	if got := h.outString(); !strings.Contains(got, "ARITH=20\n") {
		t.Fatalf("output = %q, want ARITH=20", got)
	}
}

func TestEngineForLoop(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	if st := run("for n in a b c; do echo ITEM-$n; done"); st != 0 {
		t.Fatalf("for status = %d", st)
	}
	got := h.outString()
	for _, want := range []string{"ITEM-a\n", "ITEM-b\n", "ITEM-c\n"} {
		if !strings.Contains(got, want) {
			t.Fatalf("output = %q, missing %q", got, want)
		}
	}
	// The loop variable does not leak (sh.zig unsets it).
	h.out = nil
	run("echo AFTER=$n")
	if got := h.outString(); got != "AFTER=\n" {
		t.Fatalf("loop var leaked: %q", got)
	}
}

func TestEngineIfElse(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	run("if true; then echo IF-YES; else echo IF-NO; fi")
	if got := h.outString(); got != "IF-YES\n" {
		t.Fatalf("then branch = %q", got)
	}
	h.out = nil
	run("if false; then echo IF-YES; else echo IF-NO; fi")
	if got := h.outString(); got != "IF-NO\n" {
		t.Fatalf("else branch = %q", got)
	}
	// No else and a false condition: nothing runs, $? is the condition's.
	h.out = nil
	if st := run("if false; then echo IF-YES; fi"); st != 1 {
		t.Fatalf("status = %d, want the condition's 1", st)
	}
	if h.outString() != "" {
		t.Fatalf("false condition ran a body: %q", h.outString())
	}
}

func TestEngineFunctions(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	run("fn greet(name) { echo HELLO-$name }")
	if got := h.outString(); got != "fn: ok\n" {
		t.Fatalf("definition output = %q", got)
	}
	h.out = nil
	if st := run("greet world"); st != 0 {
		t.Fatalf("call status = %d", st)
	}
	if got := h.outString(); got != "HELLO-world\n" {
		t.Fatalf("call output = %q", got)
	}
	// Positional arguments and $0 are bound as well (sh.zig bindFuncArgs).
	h.out = nil
	run("fn pos(p) { echo N0=$0 N1=$1 P=$p }")
	h.out = nil
	run("pos one")
	if got := h.outString(); got != "N0=pos N1=one P=one\n" {
		t.Fatalf("argument binding = %q", got)
	}
	// A bad definition reports and fails.
	h.out = nil
	if st := run("fn"); st != 1 {
		t.Fatalf("bad definition status = %d", st)
	}
	if !strings.Contains(h.outString(), "fn: bad definition") {
		t.Fatalf("bad definition output = %q", h.outString())
	}
}

func TestEngineCommandSubst(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	run("echo SUB=$(echo INNER)")
	if got := h.outString(); got != "SUB=INNER\n" {
		t.Fatalf("substitution = %q, want the trailing newline trimmed", got)
	}
	// The substituted text is re-tokenized, so it word-splits (reference order).
	h.out = nil
	run(`echo TWO=$(echo "a b")`)
	if got := h.outString(); got != "TWO=a b\n" {
		t.Fatalf("word split = %q", got)
	}
	// An external app's output cannot be collected: refuse, do not interleave.
	h.out = nil
	run("echo EXT=$(MISSING)")
	if !strings.Contains(h.outString(), "cannot capture an external app's output") {
		t.Fatalf("external capture output = %q", h.outString())
	}
}

func TestEngineChainsAndStatus(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	run("true && echo CHAIN-AND")
	if got := h.outString(); got != "CHAIN-AND\n" {
		t.Fatalf("&& = %q", got)
	}
	h.out = nil
	run("false || echo CHAIN-OR")
	if got := h.outString(); got != "CHAIN-OR\n" {
		t.Fatalf("|| = %q", got)
	}
	// Short-circuit really is short: the skipped half never runs, and $? is
	// still the failed condition's.
	h.out = nil
	run("false && echo CHAIN-NOPE")
	if h.outString() != "" {
		t.Fatalf("&& ran the right half of a failed condition: %q", h.outString())
	}
	h.out = nil
	run("echo RC=$?")
	if got := h.outString(); got != "RC=1\n" {
		t.Fatalf("$? after a short-circuited chain = %q", got)
	}
	// `;` runs both halves regardless.
	h.out = nil
	run("false; echo SEQ-AFTER")
	if got := h.outString(); got != "SEQ-AFTER\n" {
		t.Fatalf("; = %q", got)
	}
	// Quoted and escaped operators are not operators.
	h.out = nil
	run(`echo 'a && b'`)
	if got := h.outString(); got != "a && b\n" {
		t.Fatalf("quoted operator = %q", got)
	}
	h.out = nil
	run(`echo a \; b`)
	if got := h.outString(); got != "a ; b\n" {
		t.Fatalf("escaped operator = %q", got)
	}
}

func TestEngineChainTooLong(t *testing.T) {
	h := newFakeHost()
	run, sh := session(h)
	if st := run("echo 1; echo 2; echo 3; echo 4; echo 5"); st != 2 {
		t.Fatalf("status = %d, want the reference's 2", st)
	}
	if !strings.Contains(h.outString(), "chain too long") {
		t.Fatalf("output = %q", h.outString())
	}
	if sh.Status() != 2 {
		t.Fatalf("$? = %d, want 2", sh.Status())
	}
	// Four segments is the bound, not an error.
	h.out = nil
	if st := run("echo 1; echo 2; echo 3; echo 4"); st != 0 {
		t.Fatalf("four segments refused: %d", st)
	}
	if got := h.outString(); got != "1\n2\n3\n4\n" {
		t.Fatalf("four-segment output = %q", got)
	}
}

func TestEngineCase(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	run("set V=beta")
	h.out = nil
	run("case $V in beta) echo CASE-B;; *) echo CASE-X;; esac")
	if got := h.outString(); got != "CASE-B\n" {
		t.Fatalf("matching arm = %q", got)
	}
	// A subject that matches nothing is a success with no output.
	h.out = nil
	if st := run("case zzz in beta) echo CASE-B;; esac"); st != 0 {
		t.Fatalf("no-arm status = %d, want 0", st)
	}
	if h.outString() != "" {
		t.Fatalf("no arm matched but output = %q", h.outString())
	}
	// Globs and alternatives.
	h.out = nil
	run("case NOTES.TXT in *.BIN) echo BIN;; *.TXT) echo TXT;; esac")
	if got := h.outString(); got != "TXT\n" {
		t.Fatalf("glob arm = %q", got)
	}
}

func TestEngineSource(t *testing.T) {
	h := newFakeHost()
	h.files["SETUP.SH"] = []byte("echo SRC-1\nset RV=from-source\necho SRC-2\n")
	run, _ := session(h)
	if st := run("source SETUP.SH"); st != 0 {
		t.Fatalf("source status = %d", st)
	}
	if got := h.outString(); got != "SRC-1\nSRC-2\n" {
		t.Fatalf("sourced output = %q", got)
	}
	// Sourced lines share this shell's state, which is the whole point.
	h.out = nil
	run("echo RV=$RV")
	if got := h.outString(); got != "RV=from-source\n" {
		t.Fatalf("sourced variable = %q", got)
	}
	// `.` is the same verb.
	h.out = nil
	run(". SETUP.SH")
	if got := h.outString(); got != "SRC-1\nSRC-2\n" {
		t.Fatalf("dot form output = %q", got)
	}
	// CRLF line endings are tolerated.
	h.files["CRLF.SH"] = []byte("echo CRLF-OK\r\n")
	h.out = nil
	run("source CRLF.SH")
	if got := h.outString(); got != "CRLF-OK\n" {
		t.Fatalf("CRLF source output = %q", got)
	}
	// A missing file names the file and fails.
	h.out = nil
	if st := run("source GONE.SH"); st != 1 {
		t.Fatalf("missing source status = %d", st)
	}
	if got := h.outString(); !strings.Contains(got, "gosh: source:") || !strings.Contains(got, "GONE.SH") {
		t.Fatalf("missing source output = %q", got)
	}
}

// TestEngineSourceNestingIsBounded pins the depth guard: a file that sources
// itself must stop, and say so, rather than recursing until the guest stack
// does something worse.
func TestEngineSourceNestingIsBounded(t *testing.T) {
	h := newFakeHost()
	h.files["LOOP.SH"] = []byte("source LOOP.SH\n")
	run, _ := session(h)
	if st := run("source LOOP.SH"); st != 2 {
		t.Fatalf("self-sourcing status = %d, want 2", st)
	}
	if got := h.outString(); !strings.Contains(got, "source nesting exceeds") {
		t.Fatalf("output = %q", got)
	}
}

// TestEngineSourceTooLargeIsRefused pins the loud refusal: SH.BIN read the
// first 2048 bytes and ran a truncated script in silence.
func TestEngineSourceTooLargeIsRefused(t *testing.T) {
	h := newFakeHost()
	big := make([]byte, maxSourceBytes+64)
	for i := range big {
		big[i] = '\n'
	}
	h.files["BIG.SH"] = big
	run, _ := session(h)
	if st := run("source BIG.SH"); st != 1 {
		t.Fatalf("oversized source status = %d", st)
	}
	if got := h.outString(); !strings.Contains(got, "exceeds the") {
		t.Fatalf("output = %q", got)
	}
}

func TestEngineBreakAndContinue(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	run("for n in a b c; do echo ITEM-$n; break; done")
	if got := h.outString(); got != "ITEM-a\n" {
		t.Fatalf("break output = %q", got)
	}
	h.out = nil
	run("for n in a b c; do continue; echo LATE-$n; done")
	if h.outString() != "" {
		t.Fatalf("continue ran the rest of the body: %q", h.outString())
	}
}

func TestEngineWhileAndCap(t *testing.T) {
	h := newFakeHost()
	run, sh := session(h)
	// A condition that is false immediately leaves the loop alone.
	if st := run("while false; do echo NEVER; done"); st != 1 {
		t.Fatalf("false-condition status = %d", st)
	}
	if h.outString() != "" {
		t.Fatalf("false condition ran the body: %q", h.outString())
	}
	// A loop that never ends is stopped at the bound and SAYS so.
	h.out = nil
	if st := run("while true; do echo TICK; done"); st != 1 {
		t.Fatalf("capped loop status = %d, want 1", st)
	}
	if n := strings.Count(h.outString(), "TICK\n"); n != whileIterMax {
		t.Fatalf("iterations = %d, want %d", n, whileIterMax)
	}
	if !strings.Contains(h.outString(), "iteration cap") {
		t.Fatalf("cap was silent: %q", h.outString())
	}
	if sh.Status() != 1 {
		t.Fatalf("$? after a capped loop = %d", sh.Status())
	}
}

// TestEngineBoundsRefuseLoudly pins the slice-4 review fix: the three fixed
// arrays the reference simply stopped filling (a body's commands, a `for` word
// list, a `case` arm list) now REFUSE the line instead of quietly running a
// truncated version of it. Both halves matter: the line reports, AND none of
// the body runs — a refusal that had already executed 16 commands would be a
// silent truncation with a message attached.
func TestEngineBoundsRefuseLoudly(t *testing.T) {
	h := newFakeHost()
	run, sh := session(h)

	cmds := ""
	for i := 0; i <= bodyCmdsMax; i++ {
		if i > 0 {
			cmds += "; "
		}
		cmds += "echo BODY" + strconv.Itoa(i)
	}
	if st := run("if true; then " + cmds + "; fi"); st != 2 {
		t.Fatalf("over-long body status = %d, want 2", st)
	}
	if got := h.outString(); !strings.Contains(got, "body too long") {
		t.Fatalf("over-long body was not reported: %q", got)
	} else if strings.Contains(got, "BODY0") {
		t.Fatalf("a refused body ran anyway: %q", got)
	}
	if sh.Status() != 2 {
		t.Fatalf("$? after a refused body = %d, want 2", sh.Status())
	}

	h.out = nil
	words := ""
	for i := 0; i <= forWordMax; i++ {
		words += " w" + strconv.Itoa(i)
	}
	if st := run("for n in" + words + "; do echo LOOP-$n; done"); st != 2 {
		t.Fatalf("over-long word list status = %d, want 2", st)
	}
	if got := h.outString(); !strings.Contains(got, "for word list too long") || strings.Contains(got, "LOOP-") {
		t.Fatalf("over-long word list: %q", got)
	}

	h.out = nil
	arms := ""
	for i := 0; i <= caseArmMax; i++ {
		arms += " p" + strconv.Itoa(i) + ") echo ARM;;"
	}
	if st := run("case x in" + arms + " esac"); st != 2 {
		t.Fatalf("over-long arm list status = %d, want 2", st)
	}
	if got := h.outString(); !strings.Contains(got, "case has too many arms") || strings.Contains(got, "ARM") {
		t.Fatalf("over-long arm list: %q", got)
	}
}

// TestEngineRefusalSetsStatus pins one deliberate change from slice 4: a
// refused line now leaves $? describing the refusal. It used to return 1
// while leaving the previous $? in place, so `echo $?` after a bad line
// reported the line before it.
func TestEngineRefusalSetsStatus(t *testing.T) {
	h := newFakeHost()
	run, sh := session(h)
	run("true")
	if st := run("echo a | wc | wc"); st != 1 {
		t.Fatalf("refusal status = %d, want 1", st)
	}
	if sh.Status() != 1 {
		t.Fatalf("$? after a refusal = %d, want 1", sh.Status())
	}
}

// TestEngineToolsScriptEndToEnd is live-sh-tools' TOOLS.SH, byte for byte,
// run through the engine against a faked share. It exists because the gate
// costs a VM run to answer the same question: if the tools lane has a gap,
// this test names the missing marker in a second instead.
//
// KEEP IN SYNC WITH tools/gate/specs/live-sh-tools.spec: the script below is a
// COPY of the spec's vgate_file, not a shared source, so editing the spec
// leaves this test green against the OLD script and the drift is silent.
func TestEngineToolsScriptEndToEnd(t *testing.T) {
	h := newFakeHost()
	h.files["DATA.TXT"] = []byte("beta\nalpha\ngamma\n")
	h.files["CUT.TXT"] = []byte("one:two:three\n")
	h.files["TOOLS.SH"] = []byte(strings.Join([]string{
		"echo TOOLS-START",
		"cd /",
		"head -n 2 DATA.TXT",
		"wc -l DATA.TXT",
		"grep alpha DATA.TXT",
		"sort DATA.TXT",
		"printf TOOL-OK",
		"set V=beta",
		"case $V in beta) echo CASE-B;; *) echo CASE-X;; esac",
		"cut -d : -f 1 CUT.TXT",
		"read RV < DATA.TXT; echo READ=$RV",
		"env | grep PWD",
		"echo TOOLS-END",
	}, "\n") + "\n")
	run, _ := session(h)
	run("source TOOLS.SH")
	got := h.outString()
	// The markers the gate asserts, plus the tools lane's own distinctive
	// output (cut, head, wc) so a tool that silently does nothing cannot be
	// carried by another command's text.
	for _, want := range []string{
		"TOOLS-START\n", "alpha", "gamma", "TOOL-OK", "CASE-B", "READ=beta",
		"PWD=/\n", "TOOLS-END\n", "one\n", "beta\nalpha\n", "3 DATA.TXT",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("tools script output missing %q; got:\n%s", want, got)
		}
	}
	if strings.Contains(got, "CASE-X") {
		t.Errorf("case took the wrong arm:\n%s", got)
	}
}

// TestEngineScriptEndToEnd is the live-sh5 script, run through the engine:
// the gate's own asserts, host-testable, so a regression here is caught
// without a VM.
//
// KEEP IN SYNC WITH tools/gate/specs/live-sh5.spec: the script below is a COPY
// of the spec's vgate_file, not a shared source, so editing the spec leaves
// this test green against the OLD script and the drift is silent.
func TestEngineScriptEndToEnd(t *testing.T) {
	h := newFakeHost()
	h.files["SCRIPT.SH"] = []byte(strings.Join([]string{
		"echo SCRIPT-OK",
		"set X=$(( (2+3)*4 ))",
		"echo ARITH=$X",
		"for n in a b c; do echo ITEM-$n; done",
		"if true; then echo IF-YES; else echo IF-NO; fi",
		"fn greet(name) { echo HELLO-$name }",
		"greet world",
		"echo SUB=$(echo INNER)",
		"true && echo CHAIN-AND",
		"false || echo CHAIN-OR",
		"false && echo CHAIN-NOPE",
	}, "\n") + "\n")
	run, _ := session(h)
	// `source` reports the last command's status, and this script's last line
	// is `false && echo CHAIN-NOPE` — a short-circuited chain that leaves the
	// failed condition's 1 behind. The live gate asserts markers, not this
	// status, but the value is pinned here so it is deliberate.
	if st := run("source SCRIPT.SH"); st != 1 {
		t.Fatalf("script status = %d, want 1 (the last line's failed condition)", st)
	}
	got := h.outString()
	for _, want := range []string{
		"SCRIPT-OK\n", "ARITH=20\n", "ITEM-a\n", "ITEM-c\n", "IF-YES\n",
		"HELLO-world\n", "SUB=INNER\n", "CHAIN-AND\n", "CHAIN-OR\n",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("script output missing %q; got %q", want, got)
		}
	}
	for _, unwanted := range []string{"IF-NO", "CHAIN-NOPE"} {
		if strings.Contains(got, unwanted) {
			t.Errorf("script output must not contain %q: %q", unwanted, got)
		}
	}
}

// ---------------------------------------------------------------------------
// Heredocs (M138a, issue #2775)
// ---------------------------------------------------------------------------

// hdBodies drives the collector the way a line source does: Feed every
// following line and require all declared delimiters to close.
func hdBodies(t *testing.T, line string, feed ...string) [][]byte {
	t.Helper()
	r, err := NewHeredocReader(line)
	if err != nil {
		t.Fatalf("NewHeredocReader(%q): %v", line, err)
	}
	for _, ln := range feed {
		r.Feed(ln)
	}
	if r.Waiting() {
		t.Fatalf("still waiting on <%s> after %q", r.Delim(), feed)
	}
	return r.Bodies()
}

func TestScanHeredocs(t *testing.T) {
	specs, err := scanHeredocs("cat <<EOF")
	if err != nil || len(specs) != 1 {
		t.Fatalf("specs = %+v err=%v", specs, err)
	}
	if specs[0].delim != "EOF" || !specs[0].expand || specs[0].stripTabs {
		t.Fatalf("plain spec = %+v", specs[0])
	}
	if specs[0].at != 4 || specs[0].end != 9 {
		t.Fatalf("site = %d..%d, want 4..9", specs[0].at, specs[0].end)
	}
	for _, c := range []struct {
		line          string
		delim         string
		expand, strip bool
	}{
		{"cat <<'E'", "E", false, false},
		{"cat <<\"E\"", "E", false, false},
		{"cat <<-E", "E", true, true},
		{"cat <<-'E'", "E", false, true},
		{"cat <<- 'E'", "E", false, true},
		{"cat a<<E b", "E", true, false},
		{"cat <<E\\OF", "EOF", false, false}, // \-escape quotes the delimiter
		{"cat <<'E'x", "Ex", false, false},   // adjacent segments concatenate
	} {
		specs, err := scanHeredocs(c.line)
		if err != nil || len(specs) != 1 {
			t.Fatalf("%q: specs = %+v err=%v", c.line, specs, err)
		}
		if specs[0].delim != c.delim || specs[0].expand != c.expand || specs[0].stripTabs != c.strip {
			t.Fatalf("%q: spec = %+v, want delim=%q expand=%v strip=%v",
				c.line, specs[0], c.delim, c.expand, c.strip)
		}
	}
	// Several heredocs on one line, in declaration order — `;` is still
	// text here, so this scan is the quote-aware one, not the tokenizer.
	specs, err = scanHeredocs("cat <<A; cat <<'B'")
	if err != nil || len(specs) != 2 {
		t.Fatalf("two-per-line: %+v err=%v", specs, err)
	}
	if specs[0].delim != "A" || !specs[0].expand || specs[1].delim != "B" || specs[1].expand {
		t.Fatalf("pair = %+v", specs)
	}
	// A quoted `<<`, an escaped `<`, a comment, and a `$(...)` interior.
	for _, line := range []string{`echo '<<x'`, `echo "<<x"`, `cat \<<E`} {
		if specs, err := scanHeredocs(line); err != nil || len(specs) != 0 {
			t.Fatalf("%q declared: %+v err=%v", line, specs, err)
		}
	}
	specs, _ = scanHeredocs("cat <<E # <<F is comment")
	if len(specs) != 1 || specs[0].delim != "E" {
		t.Fatalf("comment did not end the scan: %+v", specs)
	}
	specs, _ = scanHeredocs("echo $(cat <<IN)")
	if len(specs) != 1 || specs[0].delim != "IN" {
		t.Fatalf("subst interior not scanned: %+v", specs)
	}
	// ...but a `<<` inside arithmetic is a shift, not a heredoc.
	if specs, _ := scanHeredocs("echo $((1<<4)) x"); len(specs) != 0 {
		t.Fatalf("arithmetic shift declared: %+v", specs)
	}
	// The named refusals: here-strings by name, a bare << wants its word,
	// and unbalanced quoting reports the tokenizer's own errors.
	if _, err := scanHeredocs("cat <<<x"); err == nil ||
		!strings.Contains(err.Error(), "here-strings") {
		t.Fatalf("<<< err = %v", err)
	}
	if _, err := scanHeredocs("cat <<"); err == nil ||
		!strings.Contains(err.Error(), "delimiter word") {
		t.Fatalf("bare << err = %v", err)
	}
	if _, err := scanHeredocs("cat <<'E"); err == nil ||
		!strings.Contains(err.Error(), "unterminated") {
		t.Fatalf("unterminated quote err = %v", err)
	}
}

func TestHeredocReader(t *testing.T) {
	r, err := NewHeredocReader("cat <<A; cat <<B")
	if err != nil || !r.Waiting() || r.Delim() != "A" {
		t.Fatalf("reader = %+v err=%v", r, err)
	}
	r.Feed("a1")
	r.Feed("")
	r.Feed("A") // blank lines are body content
	if !r.Waiting() || r.Delim() != "B" {
		t.Fatalf("after A: waiting=%v delim=%q", r.Waiting(), r.Delim())
	}
	r.Feed("b1")
	r.Feed("B")
	if r.Waiting() {
		t.Fatal("still waiting after B")
	}
	got := r.Bodies()
	if len(got) != 2 || string(got[0]) != "a1\n\n" || string(got[1]) != "b1\n" {
		t.Fatalf("bodies = %q", got)
	}
	// `<<-` strips leading tabs on body lines and tolerates them on the
	// terminator; a plain `<<` demands the delimiter byte-exact.
	r, _ = NewHeredocReader("cat <<-E")
	r.Feed("\t\tone")
	r.Feed("\ttwo")
	r.Feed("\tE")
	if r.Waiting() || string(r.Bodies()[0]) != "one\ntwo\n" {
		t.Fatalf("strip bodies = %q waiting=%v", r.Bodies(), r.Waiting())
	}
	r, _ = NewHeredocReader("cat <<E")
	r.Feed("\tE") // indented terminator is body text for <<, not a close
	r.Feed("E")
	if r.Waiting() || string(r.Bodies()[0]) != "\tE\n" {
		t.Fatalf("exact bodies = %q waiting=%v", r.Bodies(), r.Waiting())
	}
}

// runB is session's run for a line carrying collected heredoc bodies.
func runB(sh *Shell, line string, bodies [][]byte) int {
	st, _ := sh.RunLineBodies(line, bodies)
	return st
}

func TestEngineHeredocExpand(t *testing.T) {
	h := newFakeHost()
	run, sh := session(h)
	run("set V=hi")
	h.out = nil
	line := "cat <<EOF"
	st := runB(sh, line, hdBodies(t, line,
		"got $V", "rc=$?", "sub=$(echo IN)", "arith=$((2+3))", "EOF"))
	if st != 0 {
		t.Fatalf("heredoc status = %d", st)
	}
	if got := h.outString(); got != "got hi\nrc=0\nsub=IN\narith=5\n" {
		t.Fatalf("body = %q", got)
	}
	// ${NAME} and escapes: \$ and \\ are literal, \x stays.
	h.out = nil
	st = runB(sh, line, hdBodies(t, line, "b=${V}!", `esc\$V`, `back\\slash`, "EOF"))
	if got := h.outString(); got != "b=hi!\nesc$V\nback\\slash\n" {
		t.Fatalf("body = %q", got)
	}
}

func TestEngineHeredocQuoted(t *testing.T) {
	h := newFakeHost()
	run, sh := session(h)
	run("set V=hi")
	h.out = nil
	for _, decl := range []string{"cat <<'E'", "cat <<\"E\""} {
		if st := runB(sh, decl, hdBodies(t, decl, "lit $V $(x)", "E")); st != 0 {
			t.Fatalf("%s status = %d", decl, st)
		}
	}
	if got := h.outString(); got != "lit $V $(x)\nlit $V $(x)\n" {
		t.Fatalf("quoted bodies = %q", got)
	}
}

func TestEngineHeredocStripTabs(t *testing.T) {
	h := newFakeHost()
	_, sh := session(h)
	line := "cat <<-E"
	st := runB(sh, line, hdBodies(t, line, "\tone", "\t\ttwo", "\tE"))
	if st != 0 {
		t.Fatalf("status = %d", st)
	}
	if got := h.outString(); got != "one\ntwo\n" {
		t.Fatalf("stripped body = %q", got)
	}
}

func TestEngineHeredocMultiple(t *testing.T) {
	h := newFakeHost()
	_, sh := session(h)
	line := "cat <<A; cat <<B"
	st := runB(sh, line, hdBodies(t, line, "a1", "A", "b1", "B"))
	if st != 0 {
		t.Fatalf("status = %d", st)
	}
	if got := h.outString(); got != "a1\nb1\n" {
		t.Fatalf("outputs = %q", got)
	}
}

func TestEngineHeredocWritesFile(t *testing.T) {
	h := newFakeHost()
	run, sh := session(h)
	run("set GREET=hello-vars")
	h.out = nil
	line := "cat <<HDOC > /host/HOUT.TXT"
	if st := runB(sh, line, hdBodies(t, line,
		"expanded $GREET", "HDOC")); st != 0 {
		t.Fatalf("status = %d", st)
	}
	line = "cat <<'QT' >> /host/HOUT.TXT"
	if st := runB(sh, line, hdBodies(t, line,
		"literal $GREET", "QT")); st != 0 {
		t.Fatalf("quoted status = %d", st)
	}
	if got := string(h.files["/host/HOUT.TXT"]); got != "expanded hello-vars\nliteral $GREET\n" {
		t.Fatalf("file = %q", got)
	}
}

func TestEngineHeredocInSource(t *testing.T) {
	h := newFakeHost()
	h.files["HD.SH"] = []byte("set V=fromfile\ncat <<EOF\nfile says $V\nEOF\n")
	run, _ := session(h)
	if st := run("source HD.SH"); st != 0 {
		t.Fatalf("source status = %d", st)
	}
	if got := h.outString(); got != "file says fromfile\n" {
		t.Fatalf("output = %q", got)
	}
}

func TestEngineHeredocUnterminated(t *testing.T) {
	h := newFakeHost()
	// A script that ends mid-body refuses with the delimiter's name.
	h.files["HD.SH"] = []byte("cat <<DONE\nnever closed\n")
	run, _ := session(h)
	if st := run("source HD.SH"); st != 1 {
		t.Fatalf("status = %d, want 1", st)
	}
	if got := h.outString(); !strings.Contains(got, "gosh: heredoc: unterminated <DONE>") {
		t.Fatalf("output = %q", got)
	}
	// The headless/RunLine path (no line source) refuses the same way.
	h.out = nil
	if st := run("cat <<DONE"); st != 1 {
		t.Fatalf("RunLine status = %d", st)
	}
	if got := h.outString(); !strings.Contains(got, "gosh: heredoc: unterminated <DONE>") {
		t.Fatalf("RunLine output = %q", got)
	}
}

func TestEngineHerestringRefused(t *testing.T) {
	h := newFakeHost()
	run, _ := session(h)
	if st := run("cat <<<x"); st != 1 {
		t.Fatalf("<<< status = %d", st)
	}
	if got := h.outString(); !strings.Contains(got, "here-strings") {
		t.Fatalf("<<< output = %q", got)
	}
	h.out = nil
	if st := run("cat <<"); st != 1 {
		t.Fatalf("bare << status = %d", st)
	}
	if got := h.outString(); !strings.Contains(got, "delimiter word") {
		t.Fatalf("bare << output = %q", got)
	}
}

// A heredoc inside a construct body is bound once — the rewrite — and
// still found on every re-run, expanding against each iteration's vars.
func TestEngineHeredocInLoopBody(t *testing.T) {
	h := newFakeHost()
	_, sh := session(h)
	line := "for n in a b; do cat <<EOF; done"
	st := runB(sh, line, hdBodies(t, line, "n=$n", "EOF"))
	if st != 0 {
		t.Fatalf("status = %d", st)
	}
	if got := h.outString(); got != "n=a\nn=b\n" {
		t.Fatalf("loop bodies = %q", got)
	}
	// `if` bodies find their heredoc too.
	h.out = nil
	line = "if true; then cat <<EOF; fi"
	st = runB(sh, line, hdBodies(t, line, "inside", "EOF"))
	if st != 0 || h.outString() != "inside\n" {
		t.Fatalf("if body: st=%d out=%q", st, h.outString())
	}
}

// read prefers a bound stdin — a heredoc supplies it like `< file` does.
func TestEngineHeredocFeedsRead(t *testing.T) {
	h := newFakeHost()
	_, sh := session(h)
	line := "read X <<E"
	if st := runB(sh, line, hdBodies(t, line, "first", "second", "E")); st != 0 {
		t.Fatalf("read status = %d", st)
	}
	runB(sh, "echo GOT=$X", nil)
	if got := h.outString(); got != "GOT=first\n" {
		t.Fatalf("read output = %q", got)
	}
}
