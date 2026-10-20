package main

import "testing"

func TestBacklogBound(t *testing.T) {
	b := NewBacklog(BacklogCap)
	for i := 0; i < 300; i++ {
		b.Add(Entry{Kind: EntryMsg, Text: string(rune('a'+i%26)) + string(rune('0'+i%10)), At: int64(i)})
	}
	if b.Len() != BacklogCap {
		t.Fatalf("Len=%d want %d", b.Len(), BacklogCap)
	}
	if b.Dropped() != 44 {
		t.Fatalf("Dropped=%d want 44", b.Dropped())
	}
	es := b.Entries()
	if len(es) != BacklogCap {
		t.Fatalf("Entries=%d", len(es))
	}
	// Oldest survivor is #44, newest is #299.
	if es[0].At != 44 || es[BacklogCap-1].At != 299 {
		t.Fatalf("oldest=%d newest=%d", es[0].At, es[BacklogCap-1].At)
	}
	for i, e := range es {
		if e.At != int64(44+i) {
			t.Fatalf("entry[%d].At=%d want %d", i, e.At, 44+i)
		}
	}
}

func TestBacklogOrderAndAt(t *testing.T) {
	b := NewBacklog(4)
	for i := 0; i < 4; i++ {
		b.Add(Entry{Text: "e", At: int64(i)})
	}
	b.Add(Entry{Text: "new", At: 9})
	if b.At(0).At != 1 || b.At(3).At != 9 {
		t.Fatalf("ring order broken: %d %d", b.At(0).At, b.At(3).At)
	}
	if b.At(-1).Text != "" || b.At(4).Text != "" {
		t.Fatal("out-of-range At must be zero Entry")
	}
}
