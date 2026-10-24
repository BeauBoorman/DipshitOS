package keys

import "testing"

func TestDecodeArrowsAndEditing(t *testing.T) {
	cases := []struct {
		in   string
		key  Key
		used int
	}{
		{"\x1b[A", KeyUp, 3},
		{"\x1b[B", KeyDown, 3},
		{"\x1b[C", KeyRight, 3},
		{"\x1b[D", KeyLeft, 3},
		{"\x1b[H", KeyHome, 3},
		{"\x1b[F", KeyEnd, 3},
		{"\x1b[5~", KeyPageUp, 4},
		{"\x1b[6~", KeyPageDown, 4},
		{"\x1b", KeyEsc, 1},
		{"\x1b[Z", KeyEsc, 1}, // unknown CSI degrades to ESC
		{"\r", KeyEnter, 1},
		{"\n", KeyEnter, 1},
		{"\x7f", KeyBackspace, 1},
		{"\x08", KeyBackspace, 1},
		{"\t", KeyTab, 1},
		{"\x03", KeyCtrlC, 1},
	}
	for _, c := range cases {
		ev, n := Decode([]byte(c.in))
		if ev.Key != c.key || n != c.used {
			t.Errorf("Decode(%q) = {%v,%d}, want {%v,%d}", c.in, ev.Key, n, c.key, c.used)
		}
	}
}

func TestDecodePrintable(t *testing.T) {
	ev, n := Decode([]byte("q"))
	if ev.Key != KeyRune || ev.Rune != 'q' || n != 1 {
		t.Fatalf("Decode(q) = %+v n=%d", ev, n)
	}
	ev, n = Decode([]byte("Z9 ."))
	if ev.Key != KeyRune || ev.Rune != 'Z' || n != 1 {
		t.Fatalf("Decode(Z) = %+v n=%d", ev, n)
	}
}

// TestDecodePartialEscape proves a lone ESC byte never stalls: it is consumed
// as ESC so the next byte is decoded on its own.
func TestDecodePartialEscape(t *testing.T) {
	ev, n := Decode([]byte("\x1b["))
	if ev.Key != KeyEsc || n != 1 {
		t.Fatalf("partial CSI = %+v n=%d, want Esc/1", ev, n)
	}
	ev, n = Decode([]byte("\x1b["))
	if ev.Key != KeyEsc {
		t.Fatalf("again = %+v", ev)
	}
}

func TestDecodeEmptyAndControl(t *testing.T) {
	if ev, n := Decode(nil); ev.Key != KeyNone || n != 0 {
		t.Fatalf("empty = %+v n=%d", ev, n)
	}
	if ev, n := Decode([]byte{0x01}); ev.Key != KeyNone || n != 1 {
		t.Fatalf("ctrl-a = %+v n=%d (must be ignored, not inserted)", ev, n)
	}
}

// M121e (#2568): ctrl+z (0x1a) decodes to KeyCtrlZ — the tty spelling of
// the seat's undo chord.
func TestDecodeCtrlZ(t *testing.T) {
	ev, n := Decode([]byte{0x1a, 'x'})
	if n != 1 || ev.Key != KeyCtrlZ {
		t.Fatalf("Decode(0x1a) = (%+v, %d) want (KeyCtrlZ, 1)", ev, n)
	}
}

// M190d (#3239): the kernel's function-key and editing-key spellings —
// xterm's SS3 (F1-F4) and CSI-tilde (editing keys + F5-F12) forms, in the
// usages kernel/src/input.zig emits.
func TestDecodeFunctionKeys(t *testing.T) {
	cases := []struct {
		in   string
		want Key
		n    int
	}{
		{"\x1bOP", KeyF1, 3},
		{"\x1bOS", KeyF4, 3},
		{"\x1b[2~", KeyInsert, 4},
		{"\x1b[3~", KeyDelete, 4},
		{"\x1b[7~", KeyHome, 4},
		{"\x1b[8~", KeyEnd, 4},
		{"\x1b[15~", KeyF5, 5},
		{"\x1b[20~", KeyF9, 5},
		{"\x1b[21~", KeyF10, 5},
		{"\x1b[23~", KeyF11, 5},
		{"\x1b[24~", KeyF12, 5},
	}
	for _, tc := range cases {
		ev, n := Decode([]byte(tc.in))
		if ev.Key != tc.want || n != tc.n {
			t.Fatalf("Decode(%q) = (%+v, %d), want (%v, %d)",
				tc.in, ev, n, tc.want, tc.n)
		}
	}
	// A modifier parameter is a form Decode cannot spell: it degrades to
	// the same bare ESC a partial sequence gets, never a phantom key.
	if ev, n := Decode([]byte("\x1b[21;5~")); ev.Key != KeyEsc || n != 1 {
		t.Fatalf("modified F10 = (%+v, %d), want Esc/1", ev, n)
	}
}
