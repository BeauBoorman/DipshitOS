//go:build virelai

package term

import (
	"fmt"

	"virelai/teatty"
)

// The guest's terminal is the kernel's bound /dev/tty painted into a
// GOTABWM-hosted window — there is no termios, no ioctl and no host fd
// behind it, so every answer comes from teatty, the adapter that owns
// the binding (the v2 counterpart of v1's gsport/tty answers):
//
//	isTerminal -> "fd is the bound tty handle" (initInput's gate)
//	getSize    -> last-known CELL size, seeded at bind and refreshed by
//	              every WIN_RESIZE the Program's event goroutine sees
//	              (checkResize stays honest with no TIOCGWINSZ)
//	makeRaw/getState/setState/restore -> honest no-ops: there is no line
//	              discipline to enter or restore — no cooked mode, no
//	              echo flip, no signal generation. Returning a live
//	              State keeps Bubble Tea's restore path exercised.
//	readPassword -> refused by name (nothing calls it).
type state struct{}

func isTerminal(fd uintptr) bool { return teatty.IsBoundFd(fd) }

func makeRaw(fd uintptr) (*State, error) {
	if !teatty.IsBoundFd(fd) {
		return nil, fmt.Errorf("terminal: fd %d is not the bound /dev/tty", fd)
	}
	return &State{}, nil
}

func getState(fd uintptr) (*State, error) { return &State{}, nil }

func restore(fd uintptr, state *State) error {
	if state == nil {
		return fmt.Errorf("terminal: nil state")
	}
	return nil
}

func getSize(fd uintptr) (width, height int, err error) {
	if !teatty.IsBoundFd(fd) {
		return 0, 0, fmt.Errorf("terminal: fd %d is not the bound /dev/tty", fd)
	}
	w, h := teatty.Size()
	return w, h, nil
}

func setState(fd uintptr, state *State) error {
	if state == nil {
		return fmt.Errorf("terminal: nil state")
	}
	return nil
}

func readPassword(fd uintptr) ([]byte, error) {
	return nil, fmt.Errorf("terminal: ReadPassword has no guest meaning")
}
