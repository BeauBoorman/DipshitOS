// Package keys decodes the guest's raw /dev/tty byte stream into abstract key
// presses.
//
// The guest has no POSIX tty and no terminfo: the window VT hands the bound
// terminal printable bytes verbatim and CSI escapes for the editing keys. The
// in-guest shell decodes the same alphabet (user/go/sh/edit.go), so the reader
// owns this translation rather than pretending a termcap database exists.
package keys

// Key is an abstract key, independent of any byte encoding.
type Key int

const (
	KeyNone Key = iota
	KeyRune
	KeyUp
	KeyDown
	KeyLeft
	KeyRight
	KeyEnter
	KeyEsc
	KeyBackspace
	KeyHome
	KeyEnd
	KeyPageUp
	KeyPageDown
	KeyTab
	KeyCtrlC
	// M121e (#2568): ctrl+z (0x1a) — the seat's undo chord as a tty byte.
	// tty-bound front-ends see the chord as this control byte, never as a
	// window KEY_DOWN; an app that does not bind it ignores it as before.
	KeyCtrlZ
	// M190d (#3239): the remaining keys the kernel's tty encoder spells —
	// editing keys and the function row in xterm's SS3/CSI-tilde forms
	// (kernel/src/input.zig emitFunctionKey/emitCsiTilde). Before this
	// decode they degraded to a bare ESC followed by literal bytes.
	KeyInsert
	KeyDelete
	KeyF1
	KeyF2
	KeyF3
	KeyF4
	KeyF5
	KeyF6
	KeyF7
	KeyF8
	KeyF9
	KeyF10
	KeyF11
	KeyF12
)

// Event is one decoded key. Rune is set only for KeyRune.
type Event struct {
	Key  Key
	Rune rune
}

// Decode consumes the front of b and returns one event plus the number of
// bytes used. A partial escape sequence is consumed one byte at a time so it
// degrades to a plain ESC rather than stalling the input loop.
func Decode(b []byte) (Event, int) {
	if len(b) == 0 {
		return Event{Key: KeyNone}, 0
	}
	c := b[0]
	switch {
	case c == 0x1b:
		if len(b) >= 3 && b[1] == 'O' {
			// SS3 <final> — xterm's unmodified F1-F4 spelling.
			switch b[2] {
			case 'P':
				return Event{Key: KeyF1}, 3
			case 'Q':
				return Event{Key: KeyF2}, 3
			case 'R':
				return Event{Key: KeyF3}, 3
			case 'S':
				return Event{Key: KeyF4}, 3
			}
		}
		if len(b) >= 3 && b[1] == '[' {
			switch b[2] {
			case 'A':
				return Event{Key: KeyUp}, 3
			case 'B':
				return Event{Key: KeyDown}, 3
			case 'C':
				return Event{Key: KeyRight}, 3
			case 'D':
				return Event{Key: KeyLeft}, 3
			case 'H':
				return Event{Key: KeyHome}, 3
			case 'F':
				return Event{Key: KeyEnd}, 3
			}
			if ev, n := csiTilde(b); n > 0 {
				return ev, n
			}
		}
		return Event{Key: KeyEsc}, 1
	case c == '\r' || c == '\n':
		return Event{Key: KeyEnter}, 1
	case c == 0x7f || c == 0x08:
		return Event{Key: KeyBackspace}, 1
	case c == '\t':
		return Event{Key: KeyTab}, 1
	case c == 0x03:
		return Event{Key: KeyCtrlC}, 1
	case c == 0x1a:
		return Event{Key: KeyCtrlZ}, 1
	case c < 0x20:
		// Other control bytes are ignored, never inserted as text.
		return Event{Key: KeyNone}, 1
	default:
		return Event{Key: KeyRune, Rune: rune(c)}, 1
	}
}

// csiTilde decodes `ESC [ <n> ~` — the kernel's editing-key and F5-F12
// tilde spellings. A ';' before the '~' marks a modifier form the caller
// cannot spell, so it degrades to a bare ESC like any partial sequence
// (0 used means the caller falls through).
func csiTilde(b []byte) (Event, int) {
	i, n := 2, 0
	for i < len(b) && i < 8 && b[i] >= '0' && b[i] <= '9' {
		n = n*10 + int(b[i]-'0')
		i++
	}
	if i == 2 || i >= len(b) || b[i] != '~' {
		return Event{}, 0
	}
	k := KeyNone
	switch n {
	case 2:
		k = KeyInsert
	case 3:
		k = KeyDelete
	case 5:
		k = KeyPageUp
	case 6:
		k = KeyPageDown
	case 7:
		k = KeyHome
	case 8:
		k = KeyEnd
	case 15:
		k = KeyF5
	case 17:
		k = KeyF6
	case 18:
		k = KeyF7
	case 19:
		k = KeyF8
	case 20:
		k = KeyF9
	case 21:
		k = KeyF10
	case 23:
		k = KeyF11
	case 24:
		k = KeyF12
	default:
		return Event{}, 0
	}
	return Event{Key: k}, i + 1
}
