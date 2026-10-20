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
	"virelai/tls"
	"virelai/vi"
)

const (
	appName         = "GOHTTPD.ELF"
	defaultPort     = 8080
	defaultTLSPort  = 8443
	maxCertDERBytes = 4096
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
	markerTLSBadCfg = "httpd: tls config "
	markerTLSAlert  = "httpd: tls alert "
	markerTLSError  = "httpd: tls error "
)

// maxPinnedBytes caps one published file. The share is the host's, so the
// server does not trust it to be small.
const maxPinnedBytes = 256 * 1024

// -------------------------------------------------------------------------

func main() {
	args := vi.Args()
	cfg := parseArgs(args)
	vi.ConsoleLine(markerStarting)

	var tlsCfg *tls.ServerConfig
	if cfg.tls {
		c := loadTLSConfig(cfg.certPath, cfg.seedPath)
		if c == nil {
			vi.ConsoleLine(markerTLSBadCfg + "load")
			vi.Exit(1)
		}
		tlsCfg = c
	}

	ln, err := vi.SocketListen(cfg.port)
	if err != nil {
		vi.ConsoleLine(markerFailed)
		vi.Exit(1)
	}
	vi.ConsoleLine(markerListening + vi.Itoa64(int64(cfg.port)))

	// The accept loop hands every ESTABLISHED child its own Conn; the
	// listener itself stays live, so session close IS the relisten. The
	// kernel's child_limit=2 bounds pending children — a third
	// simultaneous SYN is honestly refused, not queued. An idle listener
	// lets the bounded AcceptConn expire and the daemon exits cleanly;
	// a kernel kill interrupts the same wait the same way. In TLS mode the
	// handshake happens here: a refused client is answered by its named
	// alert and the listener moves on.
	for {
		child, err := ln.AcceptConn()
		if err != nil {
			break
		}
		vi.ConsoleLine(markerAccepted)
		if tlsCfg != nil {
			tc, terr := tls.Server(child, *tlsCfg)
			if terr != nil {
				if name, ok := tls.ServerAlertName(terr); ok {
					vi.ConsoleLine(markerTLSAlert + name)
				} else {
					vi.ConsoleLine(markerTLSError + terr.Error())
				}
				vi.ConsoleLine(markerClosed)
				continue
			}
			serveConn(tc)
			_ = tc.Close()
		} else {
			serveConn(viStream{child})
			_ = child.Close()
		}
		vi.ConsoleLine(markerClosed)
	}
	_ = ln.Close()
	vi.ConsoleLine(markerBye)
	vi.Exit(0)
}

// connStream is the byte stream serveConn answers on: a plaintext child
// Conn, or an established TLSConn — same read/write shape either way.
type connStream interface {
	Read(p []byte) (int, error)
	Write(p []byte) (int, error)
}

// viStream adapts the per-handle child Conn to connStream (Recv/Send).
type viStream struct{ c *vi.Conn }

func (s viStream) Read(p []byte) (int, error)  { return s.c.Recv(p) }
func (s viStream) Write(p []byte) (int, error) { return s.c.Send(p) }

// serveConn runs one connection's request loop: split each complete request
// head off the buffered stream (pipelined bytes stay for the next turn),
// answer, and continue while the resolved Connection semantics say
// keep-alive. A parse failure is answered 400 and closed; a 405 likewise
// closes (the request's body extent is unknowable, so the stream cannot be
// trusted to resync). Read failures end the session, never the daemon.
func serveConn(c connStream) {
	buf := make([]byte, 0, maxRequestBytes)
	chunk := make([]byte, vi.TCPPayloadMax)
	for {
		req, resp, rest, ok := serveTurn(buf, func(rel string) []byte { return readWholeFile(rel, maxPinnedBytes) })
		if !ok {
			if len(buf) >= maxRequestBytes {
				answerAndClose(c, badRequest())
				return
			}
			n, err := c.Read(chunk)
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
		if _, err := c.Write(formatResponse(resp, req.Method == "HEAD", keepAlive)); err != nil {
			return
		}
		vi.ConsoleLine(markerServed)
		if !keepAlive {
			return
		}
	}
}

// answerAndClose emits one terminal response with Connection: close.
func answerAndClose(c connStream, resp response) {
	_, _ = c.Write(formatResponse(resp, false, false))
	vi.ConsoleLine(markerServed)
}

// config is the parsed argv: plaintext on defaultPort, or --tls <cert>
// <seed> on defaultTLSPort (both loadable share files).
type config struct {
	port     uint16
	tls      bool
	certPath string
	seedPath string
}

func parseArgs(args []string) config {
	cfg := config{port: defaultPort}
	explicitPort := false
	for i := 0; i < len(args); i++ {
		if args[i] == "--tls" {
			if i+2 >= len(args) {
				cfg.tls = false
				break
			}
			cfg.tls = true
			cfg.certPath = args[i+1]
			cfg.seedPath = args[i+2]
			i += 2
			continue
		}
		if p, ok := atoiPort(args[i]); ok {
			cfg.port = p
			explicitPort = true
		}
	}
	if cfg.tls && !explicitPort {
		cfg.port = defaultTLSPort
	}
	return cfg
}

// loadTLSConfig reads the DER certificate and 32-byte Ed25519 seed from the
// share. A missing/mis-shaped file is a nil config — main logs and exits.
func loadTLSConfig(certPath, seedPath string) *tls.ServerConfig {
	certDER := readWholeFile(certPath, maxCertDERBytes)
	seedBytes := readWholeFile(seedPath, 64)
	if len(certDER) == 0 || len(seedBytes) != 32 {
		return nil
	}
	var seed [32]byte
	copy(seed[:], seedBytes)
	return &tls.ServerConfig{Chain: [][]byte{certDER}, Ed25519Seed: seed}
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
