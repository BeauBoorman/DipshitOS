package linebuf

import "testing"

func TestLineBufferEditingAndBound(t *testing.T) {
	b := NewLineBuffer(4)
	if !b.InsertByte('a') || !b.InsertByte('b') || !b.InsertByte('c') {
		t.Fatal("insert failed")
	}
	if b.Value() != "abc" || b.Caret() != 3 {
		t.Fatalf("value=%q caret=%d", b.Value(), b.Caret())
	}
	if !b.Left() || !b.InsertByte('X') || b.Value() != "abXc" || b.Caret() != 3 {
		t.Fatalf("mid insert=%q caret=%d", b.Value(), b.Caret())
	}
	if !b.Backspace() || b.Value() != "abc" || b.Caret() != 2 {
		t.Fatalf("backspace=%q caret=%d", b.Value(), b.Caret())
	}
	if !b.Delete() || b.Value() != "ab" {
		t.Fatalf("delete=%q", b.Value())
	}
	if !b.InsertByte('d') || b.Value() != "abd" {
		t.Fatalf("insert after delete=%q", b.Value())
	}
	if !b.InsertByte('e') || b.Value() != "abde" {
		t.Fatalf("fill bound=%q", b.Value())
	}
	if b.InsertByte('f') || b.Value() != "abde" {
		t.Fatalf("bound=%q", b.Value())
	}
	b.SetValue("toolong")
	if b.Value() != "tool" || b.Caret() != 4 {
		t.Fatalf("set value=%q caret=%d", b.Value(), b.Caret())
	}
}
