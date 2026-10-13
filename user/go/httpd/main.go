// Command httpd is GOHTTPD.ELF — the M71l (#1571) Go replacement for the Zig
// HTTPD.BIN, second pass (#2200): an in-guest persistent HTTP/1.1 publisher
// that passively opens one port so a host on the NAT bridge can fetch this
// share.
//
// It listens on one TCP port (default 8080) on the slot-80 handle listener
// (vi.SocketListen) — the same surface GOSSHD.ELF uses — and serves
// connections serially: every ESTABLISHED child is its own per-handle Conn,
// answered, closed, and the listener takes the next one. One connection can
// carry several requests (keep-alive); the session ends on the peer's FIN,
// a Connection: close answer, or the bounded recv budget lapsing.
//
// Not on the boot path.
package main

import (
	"virelai/vi"
)

const (
	appName     = "GOHTTPD.ELF"
	defaultPort = 8080
)

const (
	markerStarting  = "httpd: starting"
	markerListening = "httpd: listening on port "
	markerAccepted  = "httpd: accepted"
	markerRequest   = "httpd: request "
	markerServed    = "httpd: served"
	markerClosed    = "httpd: closed"
	markerBye       = "httpd: bye"
	markerFailed    = "httpd: listen failed"
)

// maxPinnedBytes caps one published file. The share is the host's, so the
// server does not trust it to be small.
const maxPinnedBytes = 256 * 1024

// argvEnvpGuard keeps the writable segment's bss end far enough from the page
// boundary for the kernel's packed argv+envp (see GOSSHD.ELF / GOSH.ELF). The
// size is chosen so this binary's writable segment leaves well over the 0x908
// bytes of page slack the kernel's first mmap needs; the build script verifies
// it and says so by name if a future edit moves the segment end.
var argvEnvpGuard [0x4000]byte

func init() {
	argvEnvpGuard[len(argvEnvpGuard)-1] = byte(len(argvEnvpGuard) & 0xff)
}

func main() {
	port := listenPort(vi.Args())
	vi.ConsoleLine(markerStarting)

	ln, err := vi.SocketListen(port)
	if err != nil {
		vi.ConsoleLine(markerFailed)
		vi.Exit(1)
	}
	vi.ConsoleLine(markerListening + vi.Itoa64(int64(port)))

	// The accept loop hands every ESTABLISHED child its own Conn; the
	// listener itself stays live, so session close IS the relisten. The
	// kernel's child_limit=2 bounds pending children — a third
	// simultaneous SYN is honestly refused, not queued. An idle listener
	// lets the bounded AcceptConn expire and the daemon exits cleanly;
	// a kernel kill interrupts the same wait the same way.
	for {
		child, err := ln.AcceptConn()
		if err != nil {
			break
		}
		vi.ConsoleLine(markerAccepted)
		serveConn(child)
		_ = child.Close()
		vi.ConsoleLine(markerClosed)
	}
	_ = ln.Close()
	vi.ConsoleLine(markerBye)
	vi.Exit(0)
}

// serveConn runs one connection's request loop: split each complete request
// head off the buffered stream (pipelined bytes stay for the next turn),
// answer, and continue while the resolved Connection semantics say
// keep-alive. A parse failure is answered 400 and closed; a 405 likewise
// closes (the request's body extent is unknowable, so the stream cannot be
// trusted to resync). Read failures end the session, never the daemon.
func serveConn(c *vi.Conn) {
	buf := make([]byte, 0, maxRequestBytes)
	chunk := make([]byte, vi.TCPPayloadMax)
	for {
		req, resp, rest, ok := serveTurn(buf, func(rel string) []byte { return readWholeFile(rel, maxPinnedBytes) })
		if !ok {
			if len(buf) >= maxRequestBytes {
				answerAndClose(c, badRequest())
				return
			}
			n, err := c.Recv(chunk)
			if err != nil {
				return
			}
			if n > 0 {
				buf = append(buf, chunk[:n]...)
			}
			continue
		}
		buf = rest
		if resp.Status == 400 {
			// A bad head cannot resync the stream; serveTurn already
			// answered it — close after the response goes out.
			answerAndClose(c, resp)
			return
		}
		vi.ConsoleLine(markerRequest + req.RawTarget)

		// Error statuses the stream cannot resync after (a malformed head,
		// a method whose body we never read) close regardless of the
		// client's keep-alive ask; a 404 keeps the connection.
		keepAlive := !req.wantClose() && resp.Status != 405
		if _, err := c.Send(formatResponse(resp, req.Method == "HEAD", keepAlive)); err != nil {
			return
		}
		vi.ConsoleLine(markerServed)
		if !keepAlive {
			return
		}
	}
}

// answerAndClose emits one terminal response with Connection: close.
func answerAndClose(c *vi.Conn, resp response) {
	_, _ = c.Send(formatResponse(resp, false, false))
	vi.ConsoleLine(markerServed)
}

// readWholeFile reads up to max bytes of a share file, or nil if it cannot
// be opened. Same shape as the browser's reader (see user/go/browser/text.go).
func readWholeFile(path string, max int) []byte {
	h, rc := vi.FileOpen(path, vi.ModeRead)
	if rc < 0 || h < 0 {
		return nil
	}
	defer vi.FileClose(uint32(h))
	out := make([]byte, 0, 4096)
	buf := make([]byte, 16*1024)
	for len(out) < max {
		n, rr := vi.FileRead(uint32(h), buf)
		if rr < 0 || n <= 0 {
			break
		}
		take := n
		if len(out)+take > max {
			take = max - len(out)
		}
		out = append(out, buf[:take]...)
		if take < n {
			break
		}
	}
	return out
}

// listenPort takes the first argv entry that parses as a port, else the default.
func listenPort(args []string) uint16 {
	for _, a := range args {
		if p, ok := atoiPort(a); ok {
			return p
		}
	}
	return defaultPort
}

func atoiPort(s string) (uint16, bool) {
	if s == "" || len(s) > 5 {
		return 0, false
	}
	var n int
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
		if n > 65535 {
			return 0, false
		}
	}
	if n == 0 {
		return 0, false
	}
	return uint16(n), true
}
