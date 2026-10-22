// Command sshd is GOSSHD.ELF — the M70g G1 (#1491) in-guest SSH-2 server.
//
// Listens on one TCP port (default 2222) on the slot-80 handle listener
// (vi.SocketListen), speaks the ADR 0025 D2 profile as a server,
// authenticates publickey against SSH/AUTHORIZED_KEYS, and pipes each
// session exec to GOSH.ELF -c. M99g (#2185): every accepted child is its
// own per-handle Conn served on its own goroutine, so the kernel's
// two-children-per-listener bound translates directly into two
// concurrent SSH sessions. Not on the boot path.
package main

import (
	"strings"
	"sync"

	"virelai/vi"
)

const (
	appName        = "GOSSHD.ELF"
	defaultPort    = 2222
	hostSecretName = "ssh-host-ed25519"
	authKeysPath   = "SSH/AUTHORIZED_KEYS"
	markerListen   = "sshd: listen "
	markerAccepted = "sshd: accepted"
	markerKex      = "sshd: kex-ok"
	markerAuth     = "sshd: auth-ok "
	markerExec     = "sshd: exec "
	markerGosh     = "sshd: gosh rc="
	markerBye      = "sshd: bye"
	markerErr      = "sshd: error "
)

func main() {
	port := listenPort(vi.Args())
	seed, ok := loadHostSeed()
	if !ok {
		vi.ConsoleLine(markerErr + "missing ssh-host-ed25519")
		vi.Exit(1)
	}
	keys, ok := loadAuthKeys()
	if !ok || len(keys) == 0 {
		wipe(seed[:])
		vi.ConsoleLine(markerErr + "missing SSH/AUTHORIZED_KEYS")
		vi.Exit(1)
	}
	ln, err := vi.SocketListen(port)
	if err != nil {
		wipe(seed[:])
		vi.ConsoleLine(markerErr + "listen")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerListen + vi.Itoa64(int64(port)))

	// The accept loop hands every ESTABLISHED child its own Conn and its
	// own goroutine; the kernel's child_limit=2 is what bounds live
	// sessions. A third simultaneous SYN waits in the table until a
	// session slot frees; an idle listener lets the bounded AcceptConn
	// expire and the daemon exits cleanly.
	var wg sync.WaitGroup
	var failedMu sync.Mutex
	failed := false
	sessionN := 0
	for {
		child, err := ln.AcceptConn()
		if err != nil {
			break
		}
		vi.ConsoleLine(markerAccepted)
		idx := sessionN
		sessionN++
		wg.Add(1)
		go func(c *vi.Conn, i int) {
			defer wg.Done()
			defer c.Close()
			if rc := serveSession(c, i, seed, keys); rc != 0 {
				failedMu.Lock()
				failed = true
				failedMu.Unlock()
			}
		}(child, idx)
	}
	wg.Wait()
	_ = ln.Close()
	wipe(seed[:])
	if failed {
		vi.Exit(1)
	}
	vi.ConsoleLine(markerBye)
	vi.Exit(0)
}

// serveSession runs one SSH-2 session on its own per-handle Conn — the
// pre-M99g session body, unchanged except the peer is the accepted child
// rather than the singleton socket. Returns nonzero when the transport
// or the SSH machine failed.
func serveSession(c *vi.Conn, idx int, seed [32]byte, keys []AuthKey) int {
	var authDesc string
	srv := newServer(serverConfig{
		HostSeed: seed,
		Keys:     keys,
		Run:      func(cmd string) ([]byte, uint32, error) { return runGosh(cmd, execOutPath(idx)) },
		Log: func(line string) {
			logLine(line)
			if d := strings.TrimPrefix(line, "publickey accepted "); d != line {
				authDesc = d
			}
		},
		Entropy: fillRandom,
	})
	var leftover []byte
	rc := 0
	for !srv.Closed() {
		var in []byte
		if len(leftover) > 0 {
			in = leftover
			leftover = nil
		} else {
			var chunk [vi.TCPPayloadMax]byte
			n, err := c.Recv(chunk[:])
			if err != nil {
				vi.ConsoleLine(markerErr + "recv")
				rc = 1
				break
			}
			if n > 0 {
				in = append([]byte(nil), chunk[:n]...)
			}
		}
		if len(in) == 0 {
			continue
		}
		out := srv.Feed(in)
		if err := pacedSend(c, out, &leftover); err != nil {
			vi.ConsoleLine(markerErr + "send")
			rc = 1
			break
		}
		// A granted pty+shell hands the channel to the TUI (#2961), which
		// owns the rest of the session on this same goroutine.
		if srv.Session() {
			user, key := authIdentity(authDesc)
			rc = serveTUI(c, srv, &leftover, user, key)
			break
		}
	}
	if srv.Failed() {
		rc = 1
	}
	return rc
}

// authIdentity pulls the user= and key= fields out of the accepted-
// publickey log line — the session TUI shows who it is talking to and the
// key type the transport pinned.
func authIdentity(desc string) (user, key string) {
	for _, f := range strings.Fields(desc) {
		if u := strings.TrimPrefix(f, "user="); u != f {
			user = u
		}
		if k := strings.TrimPrefix(f, "key="); k != f {
			key = k
		}
	}
	return user, key
}

// execOutPath gives each session its own GOSH stdout redirect — two
// concurrent execs must not share SSH/EXEC.OUT.
func execOutPath(idx int) string {
	return "SSH/EX" + vi.Itoa64(int64(idx%16)) + ".OUT"
}

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

func fillRandom(b []byte) error {
	off := 0
	for off < len(b) {
		n, err := vi.Random(b[off:])
		if err != nil {
			return err
		}
		if n <= 0 {
			return errString("entropy")
		}
		off += n
	}
	return nil
}

type errString string

func (e errString) Error() string { return string(e) }

func logLine(line string) {
	switch {
	case strings.HasPrefix(line, "ecdh reply sent"):
		vi.ConsoleLine(markerKex)
	case strings.HasPrefix(line, "publickey accepted "):
		vi.ConsoleLine(markerAuth + strings.TrimPrefix(line, "publickey accepted "))
	case strings.HasPrefix(line, "exec ") && !strings.HasPrefix(line, "exec done"):
		vi.ConsoleLine(markerExec + strings.TrimPrefix(line, "exec "))
	}
}

func loadHostSeed() ([32]byte, bool) {
	var zero [32]byte
	var recs [vi.SecretEntriesMax]vi.SecretRecord
	n, r := vi.SecretList(recs[:])
	if r < 0 || n <= 0 {
		return zero, false
	}
	for i := 0; i < n; i++ {
		if recs[i].KeyString() != hostSecretName {
			continue
		}
		seed, ok := parseHex32(recs[i].ValString())
		wipe(recs[i].Val[:])
		return seed, ok
	}
	return zero, false
}

func loadAuthKeys() ([]AuthKey, bool) {
	b, r := vi.ReadFileAll(authKeysPath, 4096)
	if r < 0 {
		return nil, false
	}
	return parseAuthKeys(string(b))
}

func parseAuthKeys(body string) ([]AuthKey, bool) {
	lines := splitLines(body)
	if len(lines) == 0 || lines[0] != "#v1" {
		return nil, false
	}
	var keys []AuthKey
	for _, line := range lines[1:] {
		if line == "" || line[0] == '#' {
			continue
		}
		user, algo, hexKey, ok := split3(line)
		if !ok || algo != algoEd25519 {
			return nil, false
		}
		pub, ok := parseHex32(hexKey)
		if !ok {
			return nil, false
		}
		keys = append(keys, AuthKey{User: user, Pub: pub})
	}
	return keys, len(keys) > 0
}

func split3(line string) (a, b, c string, ok bool) {
	i := indexByteStr(line, '\t')
	if i < 0 {
		return "", "", "", false
	}
	j := indexByteStr(line[i+1:], '\t')
	if j < 0 {
		return "", "", "", false
	}
	j += i + 1
	return line[:i], line[i+1 : j], line[j+1:], true
}

func indexByteStr(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}

func splitLines(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			line := s[start:i]
			if len(line) > 0 && line[len(line)-1] == '\r' {
				line = line[:len(line)-1]
			}
			out = append(out, line)
			start = i + 1
		}
	}
	if start < len(s) {
		line := s[start:]
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		out = append(out, line)
	}
	return out
}

func runGosh(cmd string, outPath string) ([]byte, uint32, error) {
	if cmd == "" || strings.ContainsAny(cmd, "\n\r") {
		return nil, 1, errString("bad exec")
	}
	// The redirect is how this process reads the child's stdout back onto
	// the SSH channel. The whole line is one argv slot; over-long is refused.
	line := cmd + " > " + outPath
	if len(line) > vi.ExecArgMax {
		return nil, 1, errString("exec line")
	}
	_ = vi.FileDelete(outPath)
	pid, err := vi.Exec("GOSH.ELF", "-c", line)
	if err != nil {
		return nil, 127, err
	}
	st, err := vi.Wait(pid)
	if err != nil {
		return nil, 1, err
	}
	vi.ConsoleLine(markerGosh + vi.Itoa64(st))
	out, r := vi.ReadFileAll(outPath, 4096)
	if r < 0 {
		return nil, uint32(st), nil
	}
	return out, uint32(st), nil
}

func pacedSend(c *vi.Conn, p []byte, leftover *[]byte) error {
	for len(p) > 0 {
		take := len(p)
		if take > vi.TCPPayloadMax {
			take = vi.TCPPayloadMax
		}
		n, err := c.Send(p[:take])
		if err != nil {
			return err
		}
		if n == 0 {
			return errString("send zero")
		}
		p = p[n:]
		if len(p) == 0 {
			return nil
		}
		deadline := vi.Nanos() + vi.DefaultRecvBudgetNs
		for {
			mask, err := c.ReadyMask()
			if err != nil {
				return errString("ready")
			}
			if mask&1 != 0 {
				var buf [vi.TCPPayloadMax]byte
				nr, err := c.Recv(buf[:])
				if err != nil {
					return err
				}
				if nr > 0 {
					*leftover = append(*leftover, buf[:nr]...)
				}
			}
			if mask&2 != 0 {
				break
			}
			if vi.Nanos() >= deadline {
				return errString("send timeout")
			}
			vi.Sleep(1)
		}
	}
	return nil
}
