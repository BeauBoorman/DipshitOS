// The catch-all fallback upstream ships for platforms without termios.
// The overlay retags it to STOP covering virelai — the guest gets real
// answers from term_virelai.go (the bound /dev/tty behind the hosted
// window) instead of this file's "not implemented" errors.
// pinned-sha256: ba110230c479f4ec17261f543943e5e1e9c19a638c0f2f6c307ac53bac19863e
//
//go:build !aix && !darwin && !dragonfly && !freebsd && !linux && !netbsd && !openbsd && !zos && !windows && !solaris && !plan9 && !virelai
// +build !aix,!darwin,!dragonfly,!freebsd,!linux,!netbsd,!openbsd,!zos,!windows,!solaris,!plan9,!virelai

package term

import (
	"fmt"
	"runtime"
)

type state struct{}

func isTerminal(fd uintptr) bool {
	return false
}

func makeRaw(fd uintptr) (*State, error) {
	return nil, fmt.Errorf("terminal: MakeRaw not implemented on %s/%s", runtime.GOOS, runtime.GOARCH)
}

func getState(fd uintptr) (*State, error) {
	return nil, fmt.Errorf("terminal: GetState not implemented on %s/%s", runtime.GOOS, runtime.GOARCH)
}

func restore(fd uintptr, state *State) error {
	return fmt.Errorf("terminal: Restore not implemented on %s/%s", runtime.GOOS, runtime.GOARCH)
}

func getSize(fd uintptr) (width, height int, err error) {
	return 0, 0, fmt.Errorf("terminal: GetSize not implemented on %s/%s", runtime.GOOS, runtime.GOARCH)
}

func setState(fd uintptr, state *State) error {
	return fmt.Errorf("terminal: SetState not implemented on %s/%s", runtime.GOOS, runtime.GOARCH)
}

func readPassword(fd uintptr) ([]byte, error) {
	return nil, fmt.Errorf("terminal: ReadPassword not implemented on %s/%s", runtime.GOOS, runtime.GOARCH)
}
