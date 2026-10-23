package main

// parse_test.go — the form-reader half: quoted strings, literals,
// nested lists, NIL, and refusal of malformed records.

import "testing"

func TestParseRecord(t *testing.T) {
	rec := `* LIST (\HasNoChildren) "/" "INBOX"`
	toks, err := parseRecord([]byte(rec))
	if err != nil {
		t.Fatalf("parseRecord: %v", err)
	}
	// * LIST (flags) delim name — five tokens, name last.
	if len(toks) != 5 {
		t.Fatalf("toks %v", toks)
	}
	if s, _ := formStr(toks[0]); s != "*" {
		t.Fatalf("tok0 %v", toks[0])
	}
	if l, ok := formList(toks[2]); !ok || len(l) != 1 || formStrOr(l[0], "") != "\\HasNoChildren" {
		t.Fatalf("flags %v", toks[2])
	}
	if s, _ := formStr(toks[4]); s != "INBOX" {
		t.Fatalf("name %v", toks[4])
	}
}

func TestParseLiteralAndNIL(t *testing.T) {
	rec := "* 1 FETCH (BODY[TEXT] {6}\r\nhe<llo)"
	toks, err := parseRecord([]byte(rec))
	if err != nil {
		t.Fatalf("parseRecord literal: %v", err)
	}
	l, _ := formList(toks[3])
	if s, _ := formStr(l[1]); s != "he<llo" {
		t.Fatalf("literal %q", s)
	}
	if len(l) != 2 {
		t.Fatalf("items %v", l)
	}
	// NIL decodes to nil.
	toks2, err := parseRecord([]byte("(a NIL b)"))
	if err != nil {
		t.Fatalf("NIL parse: %v", err)
	}
	l2, _ := formList(toks2[0])
	if l2[1] != nil {
		t.Fatalf("NIL not nil: %v", l2[1])
	}
}

func TestParseRefusals(t *testing.T) {
	for _, bad := range []string{
		"(unclosed",
		"\"unclosed",
		"{3}\r\nab",        // literal short
		"{999999999}\r\nx", // over the literal bound
		"(a) (",            // trailing garbage
	} {
		if _, err := parseRecord([]byte(bad)); err == nil {
			t.Fatalf("malformed record accepted: %q", bad)
		}
	}
}
