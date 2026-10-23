package main

// The field widget's secret discipline: the buffer is bytes so it can be
// wiped, and the masked face shows bullets, never length.
import "testing"

// The masked field stores bytes so it can be wiped: backspace removes a
// whole rune (and zeroes its bytes), clear() leaves nothing recoverable.
func TestFieldWipesItsBytes(t *testing.T) {
	f := newField("secret", 8, true)
	f.insert('p')
	f.insert('a')
	f.insert('é') // two bytes — the rune-whole case
	if got := f.shown(); got != "***" {
		t.Fatalf("masked show=%q, want three bullets", got)
	}
	f.backspace()
	if string(f.buf) != "pa" {
		t.Fatalf("backspace left %q — must remove the whole é", f.buf)
	}
	f.insert('x')
	f.clear()
	for _, b := range f.buf[:cap(f.buf)] {
		if b != 0 {
			t.Fatal("clear left bytes in the field buffer")
		}
	}
	if got := f.shown(); got != "" {
		t.Fatalf("cleared field shows %q", got)
	}
}
