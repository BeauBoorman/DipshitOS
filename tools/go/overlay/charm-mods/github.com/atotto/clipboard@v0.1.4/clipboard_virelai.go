//go:build virelai

package clipboard

// atotto/clipboard v0.1.4 ships backends for unix, darwin, plan9 and
// windows only, so under GOOS=virelai readAll/writeAll would be undefined.
// textinput and textarea import this package (and list pulls it in through
// textinput), which makes the hole unavoidable for any Bubbles build: this
// file is the platform half clipboard.go's API expects.
//
// The backend is the kernel's ONE shared text clipboard — a fixed 512-byte
// buffer behind sys_clipboard_set/sys_clipboard_get (kernel/src/clipboard.zig,
// ADR 0007 slots 38/39) — reached through virelai/vsys, the same binding every
// other guest client uses. There is no clipboard daemon to spawn and no
// command to exec: Unsupported stays false because the seat clipboard is
// always present.
//
// Sizing is a contract, not a detail: the kernel clips an oversize set
// honestly at its bound and reports the stored length, so this shim refuses
// anything over the bound UP FRONT — a caller of WriteAll must never be told
// a 512-byte prefix of its payload is the whole clipboard.

import (
	"errors"

	"virelai/vsys"
)

// clipCapacity mirrors kernel/src/clipboard.zig's `capacity` (512 bytes —
// sized there to round-trip NOTEPAD's full editor buffer).
const clipCapacity = 512

var (
	errTooLarge = errors.New("clipboard: payload exceeds the 512-byte kernel bound")
	errKernel   = errors.New("clipboard: kernel slot refused the transfer")
)

func readAll() (string, error) {
	buf := make([]byte, clipCapacity)
	n, r := vsys.ClipboardGetInto(buf)
	if r < 0 {
		return "", errKernel
	}
	return string(buf[:n]), nil
}

func writeAll(text string) error {
	if len(text) > clipCapacity {
		return errTooLarge
	}
	n, r := vsys.ClipboardSetAll([]byte(text))
	if r < 0 {
		return errKernel
	}
	if n != len(text) {
		// The kernel stored a strict prefix; report the clip, never a
		// success the caller would read as a whole-payload write.
		return errTooLarge
	}
	return nil
}
