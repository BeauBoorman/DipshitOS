//go:build !virelai && !sshdtui

// An untagged build has no Bubble Tea (Charm stays out of the SDK go.mod —
// this is what keeps `go test ./sshd/...` honest). A pty+shell session
// still gets a well-formed end: exit-status 0, EOF and close, the same wire
// shape the TUI produces on `q`.
package main

import "virelai/vi"

func serveTUI(c *vi.Conn, srv *Server, leftover *[]byte, user, keyAlgo string) int {
	if err := pacedSend(c, srv.CloseSession(0), leftover); err != nil {
		return 1
	}
	return 0
}
