package find

import "testing"

// From: the forward search, the ordinal among ALL matches, and the wrap to
// the first match when nothing is at or after the caret. (Moved verbatim
// from GOEDIT's edit_test.go when the matcher was extracted, M126c #2595.)
func TestFrom(t *testing.T) {
	doc := []byte("one two one two")
	// From the caret at the end, the search wraps to the first match.
	if total, ord, off := From(doc, []byte("one"), len(doc)); total != 2 || ord != 1 || off != 0 {
		t.Fatalf("wrapped find = (%d,%d,%d) want (2,1,0)", total, ord, off)
	}
	// A caret AT the second match's start lands on it and reports ordinal 2:
	// the rule is "the first match at or after the caret".
	if total, ord, off := From(doc, []byte("one"), 8); total != 2 || ord != 2 || off != 8 {
		t.Fatalf("second-match find = (%d,%d,%d) want (2,2,8)", total, ord, off)
	}
	// A caret INSIDE a match is past that match's start, so with no match left
	// to run to the search wraps to the first one (the same rule, not a second
	// one) - which is what makes a repeat Return re-report the same single
	// match instead of inventing one.
	if total, ord, off := From(doc, []byte("one"), 9); total != 2 || ord != 1 || off != 0 {
		t.Fatalf("in-match find = (%d,%d,%d) want (2,1,0)", total, ord, off)
	}
	// Matches do not overlap: "aba" holds ONE "aba", not a sliding pair.
	if total, _, _ := From([]byte("ababa"), []byte("aba"), 0); total != 1 {
		t.Fatalf("non-overlapping total = %d want 1", total)
	}
	// No match, empty pattern, and a pattern longer than the buffer.
	if _, _, off := From(doc, []byte("zzz"), 0); off != -1 {
		t.Fatalf("no-match off = %d want -1", off)
	}
	if total, _, off := From(doc, nil, 0); total != 0 || off != -1 {
		t.Fatalf("empty pattern = (%d,%d) want (0,-1)", total, off)
	}
	if total, _, off := From([]byte("ab"), []byte("abc"), 0); total != 0 || off != -1 {
		t.Fatalf("long pattern = (%d,%d) want (0,-1)", total, off)
	}
}

// CaseSensitive pins the M66c review decision (#1495): the matcher is a
// byte compare — "The" does not match "the". The Zig app was case-
// insensitive with a compile-time constant; this is a deliberate delta.
func TestCaseSensitive(t *testing.T) {
	if got := All([]byte("The end. the"), []byte("the")); len(got) != 1 || got[0] != 9 {
		t.Fatalf("case-sensitive 'the' = %v want [9]", got)
	}
}

// All returns every non-overlapping offset in order — the list the find
// bar steps through and replace-all's splice list counts with.
func TestAll(t *testing.T) {
	if got := All([]byte("one two one two"), []byte("one")); len(got) != 2 || got[0] != 0 || got[1] != 8 {
		t.Fatalf("All 'one' = %v want [0 8]", got)
	}
	if got := All([]byte("ababa"), []byte("aba")); len(got) != 1 {
		t.Fatalf("All 'aba' in 'ababa' = %v want [0]", got)
	}
	if got := All([]byte("x"), []byte("x")); len(got) != 1 || got[0] != 0 {
		t.Fatalf("All exact = %v want [0]", got)
	}
	if got := All(nil, []byte("x")); got != nil {
		t.Fatalf("All empty buf = %v want nil", got)
	}
}

// ContainsFold is the M191b name-search predicate: folded on both sides,
// a-z onto A-Z only — "verb" reaches VERB.TXT, and the byte-exact All
// stays untouched ("verb" is not a byte match there, it is a folded one).
func TestContainsFold(t *testing.T) {
	fold := func(s string) []byte {
		b := []byte(s)
		for i := range b {
			b[i] = FoldByte(b[i])
		}
		return b
	}
	if !ContainsFold([]byte("VERB.TXT"), fold("verb")) {
		t.Fatal("lower-case needle must reach an upper-case name")
	}
	if !ContainsFold([]byte("verb.txt"), fold("VERB")) {
		t.Fatal("the fold runs both directions")
	}
	if ContainsFold([]byte("VERB.TXT"), fold("zerb")) {
		t.Fatal("a folded scan is still exact per byte")
	}
	if ContainsFold([]byte("ab"), fold("abc")) {
		t.Fatal("a needle longer than the name cannot match")
	}
	if ContainsFold([]byte("VERB.TXT"), fold("")) {
		t.Fatal("the empty needle is not a hit")
	}
	if FoldByte('a') != 'A' || FoldByte('Z') != 'Z' || FoldByte('5') != '5' {
		t.Fatal("the fold is a-z onto A-Z only")
	}
}
