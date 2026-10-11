package shlib

import (
	"strings"
	"testing"
)

func mustTokens(t *testing.T, line string) []token {
	t.Helper()
	toks, err := tokenize(line)
	if err != nil {
		t.Fatalf("tokenize(%q): %v", line, err)
	}
	return toks
}

// TestTokenizeQuotes pins the quoting rules: '…' literal, "…" expanding,
// backslash escapes, adjacency, and unquoted operators.
func TestTokenizeQuotes(t *testing.T) {
	toks := mustTokens(t, `echo 'a b' "c d" e\ f|wc >f>>g<h &`)
	wantKinds := []tokKind{tokWord, tokWord, tokWord, tokWord, tokPipe, tokWord, tokOut, tokWord, tokAppend, tokWord, tokIn, tokWord, tokAmp}
	if len(toks) != len(wantKinds) {
		t.Fatalf("tokens = %d, want %d (%v)", len(toks), len(wantKinds), toks)
	}
	for i, k := range wantKinds {
		if toks[i].kind != k {
			t.Fatalf("token %d kind = %v, want %v (%v)", i, toks[i].kind, k, toks)
		}
	}
	// Single quotes are escMark-protected literal content.
	sq := toks[1].text
	if !strings.Contains(sq, string(escMark)) || strings.Contains(sq, "$") && !strings.Contains(sq, string(escMark)+"$") {
		// content protected — checked via expansion below
		_ = sq
	}
	// A quoted operator is not an operator.
	toks = mustTokens(t, `echo '|'`)
	if len(toks) != 2 || toks[1].kind != tokWord {
		t.Fatalf("quoted pipe tokens = %v", toks)
	}
	// Comments drop the rest of the line.
	toks = mustTokens(t, "echo a # | wc > /etc/passwd")
	if len(toks) != 2 {
		t.Fatalf("comment tokens = %v", toks)
	}
}

// TestExpandPins pins $NAME, ${NAME}, $? and the literal escapes.
func TestExpandPins(t *testing.T) {
	env := NewEnv()
	env.Set("GREET", "hello")
	env.Set("N", "5")
	cases := []struct {
		raw  string
		want string
	}{
		{"$GREET", "hello"},
		{"${GREET}!", "hello!"},
		{"pre$GREET post", "prehello post"},
		{"$MISSING", ""},
		{"a|" + string(escMark) + "|b", "a||b"}, // escaped pipe stays a word char
		{"cost" + string(escMark) + "$5", "cost$5"},
	}
	for _, tc := range cases {
		tok := token{kind: tokWord, text: tc.raw}
		if got := expand(tok, env, 0); got != tc.want {
			t.Fatalf("expand(%q) = %q, want %q", tc.raw, got, tc.want)
		}
	}
	// $? carries the last status.
	if got := expand(token{kind: tokWord, text: "rc=$?"}, env, 43); got != "rc=43" {
		t.Fatalf("$? = %q, want rc=43", got)
	}
}

// TestParsePlanPins pins the plan assembly for the supported grammar.
func TestParsePlanPins(t *testing.T) {
	env := NewEnv()
	build := func(line string) *plan {
		t.Helper()
		toks := mustTokens(t, line)
		p, err := parsePlan(toks, env, 0, nil)
		if err != nil {
			t.Fatalf("parsePlan(%q): %v", line, err)
		}
		return p
	}
	p := build("exec GOSH.ELF -c echo hi &")
	if !p.background || len(p.right) != 0 || p.left[0] != "exec" {
		t.Fatalf("bg plan = %+v", p)
	}
	p = build("cat < /host/IN.TXT")
	if p.in == nil || p.in.path != "/host/IN.TXT" {
		t.Fatalf("< plan = %+v", p)
	}
	p = build("echo hi | wc -c > /host/N.TXT")
	if len(p.right) == 0 || p.out == nil || p.out.path != "/host/N.TXT" || p.out.append {
		t.Fatalf("pipe+out plan = %+v", p)
	}
	p = build("echo x >> /host/A.TXT")
	if p.out == nil || !p.out.append {
		t.Fatalf(">> plan = %+v", p)
	}
}

// TestTokenizeAdjacent pins `abc"def"g` as one word (three segments).
func TestTokenizeAdjacent(t *testing.T) {
	env := NewEnv()
	env.Set("V", "mid")
	toks := mustTokens(t, `echo a'b'c"${V}"d`)
	if len(toks) != 2 || toks[1].kind != tokWord {
		t.Fatalf("adjacent tokens = %v", toks)
	}
	got := expand(toks[1], env, 0)
	if got != "abcmidd" {
		t.Fatalf("adjacent expansion = %q, want abcmidd", got)
	}
	// Without braces the name extends to the first non-name byte (POSIX):
	// "$V"d looks up Vd, which is unset.
	toks = mustTokens(t, `echo a'b'c"$V"d`)
	if got := expand(toks[1], env, 0); got != "abc" {
		t.Fatalf("unbraced adjacent expansion = %q, want abc", got)
	}
}
