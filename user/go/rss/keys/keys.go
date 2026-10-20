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
			if len(b) >= 4 && b[3] == '~' {
				switch b[2] {
				case '5':
					return Event{Key: KeyPageUp}, 4
				case '6':
					return Event{Key: KeyPageDown}, 4
				}
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
