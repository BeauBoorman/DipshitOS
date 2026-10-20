package main

import "testing"

// brackets_test.go pins M138b (#2776): the Go span classifier, the match
// tables (nesting, same-kind depth, backward scans, the .go string/comment
// skip), the Ctrl-B chord through the live key path, and the highlight
// cell's refusal cases.

func TestClassifyGo(t *testing.T) {
	// A buffer exercising every span: line and block comments, a quoted
	// string with an escaped quote, a rune literal, and a raw string —
	// each carrying brackets that must classify as NOT code.
	src := `a { // (x)
b /* [c] */ "str(\"[)]" ` + "`raw{(}`" + ` '{' z`
	cls := classifyGo([]byte(src))
	if len(cls) != len(src) {
		t.Fatalf("classifyGo len = %d want %d", len(cls), len(src))
	}
	// The comment spans: the // to the newline (the newline itself stays
	// code), and the whole /* */.
	if cls[4] != clsCmt || cls[9] != clsCmt || cls[10] != clsCode {
		t.Fatalf("line comment classes wrong: %v", cls[4:12])
	}
	open := 13
	closed := open + len("/* [c] */") - 1
	if cls[open] != clsCmt || cls[closed] != clsCmt || cls[closed+1] != clsCode {
		t.Fatalf("block comment classes wrong")
	}
	// Brackets inside the quoted and raw strings and the rune literal are
	// all classified out of the scan.
	for i, c := range []byte(src) {
		if (c == '(' || c == ')' || c == '[' || c == ']' || c == '{' || c == '}') &&
			i != 2 && cls[i] == clsCode {
			t.Fatalf("bracket at %d misclassified as code", i)
		}
	}
	// Unterminated spans: a string cut by the newline and a block comment
	// running to EOF both stop where Go's grammar stops them.
	un := classifyGo([]byte("x \"y\nz"))
	if un[2] != clsStr || un[3] != clsStr || un[4] != clsCode {
		t.Fatalf("unterminated string must stop at the newline: %v", un)
	}
	ub := classifyGo([]byte("a /* open"))
	if ub[2] != clsCmt || ub[len(ub)-1] != clsCmt {
		t.Fatalf("unterminated comment must run to EOF: %v", ub)
	}
}

// TestMatchBracketPlain: the non-Go scan — every byte is code, so brackets
// inside what a .go file would call strings still count. The cases run
// both directions of the scan and the refusal shapes.
func TestMatchBracketPlain(t *testing.T) {
	cases := []struct {
		doc      string
		cur      int
		want     int
		wantOK   bool
	}{
		// Same-kind depth: the outer ( skips a nested () and an inner [].
		{"(a(b)c[d]e)", 0, 10, true},
		// Backward scan from the closer lands on the same opener.
		{"(a(b)c[d]e)", 10, 0, true},
		// A nested closer walks back to ITS opener, not the outer one.
		{"(a(b)c[d]e)", 4, 2, true},
		{"(a(b)c[d]e)", 6, 8, true},
		{"(a(b)c[d]e)", 8, 6, true},
		// Mixed nesting keeps its own pair: { walks over () and [].
		{"{f(x)[y]z}", 0, 9, true},
		// Unbalanced: an opener with no closer, a closer with no opener.
		{"(aa", 0, 0, false},
		{"aa)", 2, 0, false},
		// Not on a bracket at all.
		{"a(b)", 0, 0, false},
		{"a(b)", 2, 0, false},
		// The depth rule is same-kind only — `([)]` answers like Emacs %:
		// ( pairs with the first ) and [ with the ], crossing arms and all.
		{"([)]", 0, 2, true},
		{"([)]", 1, 3, true},
		// A "string" is not a span outside .go — the ( in quotes counts.
		{`a "(b" c)`, 3, 8, true},
	}
	for _, c := range cases {
		got, ok := matchBracket([]byte(c.doc), c.cur, false)
		if ok != c.wantOK || (ok && got != c.want) {
			t.Fatalf("matchBracket(%q, %d) = (%d,%v) want (%d,%v)",
				c.doc, c.cur, got, ok, c.want, c.wantOK)
		}
	}
	// Out-of-range carets refuse instead of indexing the buffer.
	if _, ok := matchBracket([]byte("(x)"), -1, false); ok {
		t.Fatal("cur=-1 must refuse")
	}
	if _, ok := matchBracket([]byte("(x)"), 4, false); ok {
		t.Fatal("cur=len must refuse")
	}
}

// TestMatchBracketGo: on a .go buffer, brackets inside strings, rune
// literals and comments are skipped — the scan's whole reason for being.
func TestMatchBracketGo(t *testing.T) {
	// The ( inside the string and the [ inside the comment do not count:
	// the outer { matches over them to the final }.
	doc := "f {\n\ts := \"(x)\"\n\t// [y]\n\tg()\n}\n"
	// The real offsets: "{" at 2, the closing "}" at len-2.
	if got, ok := matchBracket([]byte(doc), 2, true); !ok || got != len(doc)-2 {
		t.Fatalf("{ match = (%d,%v) want (%d,true)", got, ok, len(doc)-2)
	}
	if got, ok := matchBracket([]byte(doc), len(doc)-2, true); !ok || got != 2 {
		t.Fatalf("} match = (%d,%v) want (2,true)", got, ok)
	}
	// g() at 34-35 in the doc above: find them rather than hardcode.
	open, clos := 0, 0
	for i := 0; i+1 < len(doc); i++ {
		if doc[i] == 'g' && doc[i+1] == '(' {
			open, clos = i+1, i+2
		}
	}
	if got, ok := matchBracket([]byte(doc), open, true); !ok || got != clos {
		t.Fatalf("g( match = (%d,%v) want (%d,true)", got, ok, clos)
	}
	// A caret on the bracket INSIDE the string or the comment refuses:
	// it is not a bracket at all in a .go buffer.
	inStr, inCmt := 0, 0
	for i := 0; i < len(doc); i++ {
		if doc[i] == '"' {
			inStr = i + 1 // the ( right after the quote
			break
		}
	}
	for i := 0; i < len(doc); i++ {
		if doc[i] == '[' {
			inCmt = i
			break
		}
	}
	if _, ok := matchBracket([]byte(doc), inStr, true); ok {
		t.Fatal("a bracket inside a string must not match")
	}
	if _, ok := matchBracket([]byte(doc), inCmt, true); ok {
		t.Fatal("a bracket inside a comment must not match")
	}
	// The same document scanned as plain text DOES match them — the skip
	// is the .go path's behavior, not the matcher's.
	if _, ok := matchBracket([]byte(doc), inStr, false); !ok {
		t.Fatal("plain scan must see the string's bracket")
	}
	// A nested pair inside a BLOCK comment is skipped for depth too:
	// } here still walks back to { at 0.
	bc := "{ /* } ) ( ] */ x }"
	if got, ok := matchBracket([]byte(bc), len(bc)-1, true); !ok || got != 0 {
		t.Fatalf("block-comment skip = (%d,%v) want (0,true)", got, ok)
	}
}

// TestJumpMatchChord drives Ctrl-B through the live key path: the caret
// lands on the match and the selection collapses; a non-bracket caret is
// the `none` refusal and the caret stays.
func TestJumpMatchChord(t *testing.T) {
	e := usEditor("f { g() }")
	e.cur = 2 // the {
	if !e.key(usDown(0x05, modCtrl, 0x02)) { // ctrl-b: usage 0x05, arg1 0x02
		t.Fatal("ctrl-b must report a redraw")
	}
	if e.cur != 8 {
		t.Fatalf("jump cur = %d want 8 (the })", e.cur)
	}
	// And back — the chord is symmetric.
	e.key(usDown(0x05, modCtrl, 'b'))
	if e.cur != 2 {
		t.Fatalf("jump-back cur = %d want 2", e.cur)
	}
	// A caret not on a bracket: `match none`, caret unmoved.
	e.cur = 4
	e.key(usDown(0x05, modCtrl, 'b'))
	if e.cur != 4 {
		t.Fatalf("none refusal moved the caret: %d", e.cur)
	}
	// The go path: a caret on the ( inside the comment refuses too —
	// isGoPath is the switch.
	e2 := usEditor("x // (\ny\n")
	e2.path = "/host/W/main.go"
	e2.cur = 5 // the ( in the comment
	e2.key(usDown(0x05, modCtrl, 'b'))
	if e2.cur != 5 {
		t.Fatalf("go comment bracket jumped: %d", e2.cur)
	}
}

// TestMatchCell: the highlight's refusal cases — no bracket under the
// caret, a caret past the buffer, and a modal mode all report no-match.
func TestMatchCell(t *testing.T) {
	e := usEditor("{x}")
	e.cur = 0
	if m, ok := e.matchCell(); !ok || m != 2 {
		t.Fatalf("matchCell = (%d,%v) want (2,true)", m, ok)
	}
	e.cur = 1 // 'x' is not a bracket
	if _, ok := e.matchCell(); ok {
		t.Fatal("non-bracket caret must not highlight")
	}
	e.cur = 0
	e.mode = modeFind
	if _, ok := e.matchCell(); ok {
		t.Fatal("a bar must not paint the match")
	}
}

func TestIsGoPath(t *testing.T) {
	for p, want := range map[string]bool{
		"/host/W/main.go":  true,
		"/host/W/MAIN.GO":  true, // the share carries both cases
		"/host/W/seed.txt": false,
		"/host/W/gopher":   false,
		"/host/W/a.gox":    false,
		"/host/W/.go":      true, // a dotfile-suffix edge — still .go
	} {
		if got := isGoPath(p); got != want {
			t.Fatalf("isGoPath(%q) = %v want %v", p, got, want)
		}
	}
}
