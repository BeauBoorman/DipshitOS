// Command ssh is GOSSH.ELF — the M71j (#1569) in-guest SSH-2 client.
//
// Dials out over the kernel's one-slot TCP seam, speaks the ADR 0025 D2
// profile (curve25519-sha256, ssh-ed25519, chacha20-poly1305@openssh.com,
// publickey, one session exec), and reuses the Go primitives in
// virelai/sshlib (the same ones GOSSHD.ELF uses). Not on the boot path.
package main

import (
	"strings"

	"virelai/sshlib"
	"virelai/vi"
)

const (
	appName        = "GOSSH.ELF"
	userSecretName = "ssh-user-ed25519"
	knownHostsPath = "SSH/KNOWN_HOSTS"
)

func main() {
	args := vi.Args()
	if len(args) > 0 {
		args = args[1:]
	}
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printHelp()
			vi.Exit(sshlib.ExitOK)
		}
	}
	tgt, ok := parseTarget(args)
	if !ok {
		vi.ConsoleLine("ssh: usage: exec GOSSH.ELF [user@]host[:port] [command ...]")
		vi.Exit(sshlib.ExitUsage)
	}
	mode := "shell"
	if tgt.cmd != "" {
		mode = "exec"
	}
	vi.ConsoleLine("ssh: target user=" + tgt.user + " host=" + tgt.host + " port=" + uitoa(uint(tgt.port)) + " mode=" + mode)

	conn, err := vi.Dial(tgt.host, tgt.port)
	if err != nil {
		vi.ConsoleLine("ssh: fail stage=connect rc=" + uitoa(sshlib.ExitConnect))
		vi.Exit(sshlib.ExitConnect)
	}
	vi.ConsoleLine("ssh: connected")

	cfg := sshlib.ClientConfig{
		User:    tgt.user,
		Cmd:     tgt.cmd,
		Entropy: fillRandom,
	}
	if pin, found, fileOK := loadPin(tgt.host, tgt.port); fileOK && found {
		cfg.HostPin = pin
		cfg.HasPin = true
	}
	if seed, ok := loadUserSeed(); ok {
		cfg.UserSeed = seed
		cfg.HasSeed = true
	}

	kexOK := false
	chanOpen := false
	eofPrinted := false
	var cl *sshlib.Client
	cfg.Log = func(line string) {
		switch {
		case strings.HasPrefix(line, "newkeys received"):
			if !kexOK {
				kexOK = true
				vi.ConsoleLine("ssh: kex-ok")
			}
		case line == "pin ok":
			vi.ConsoleLine("ssh: pin-ok")
		case line == "publickey accepted":
			vi.ConsoleLine("ssh: auth-ok method=publickey")
		case line == "channel open":
			if cl != nil && !chanOpen {
				chanOpen = true
				vi.ConsoleLine("ssh: channel-open remote=" + uitoa(uint(cl.RemoteChan)))
			}
		case line == "eof":
			if !eofPrinted {
				eofPrinted = true
				vi.ConsoleLine("ssh: eof")
			}
		}
	}
	cl = sshlib.NewClient(cfg)
	if cfg.HasSeed {
		sshlib.Wipe(cfg.UserSeed[:])
	}

	var leftover []byte
	stdoutOff := 0
	out := cl.Start()
	if err := pacedSend(conn, out, &leftover); err != nil {
		_ = conn.Close()
		failRun(cl, kexOK)
	}
	for !cl.Closed() {
		var in []byte
		if len(leftover) > 0 {
			in = leftover
			leftover = nil
		} else {
			var n int
			var err error
			in, n, err = recvWait()
			if err != nil {
				break
			}
			drainRX(&leftover)
			if n == vi.TCPPayloadMax {
				for spins := 0; spins < 8 && len(leftover) == 0; spins++ {
					vi.Sleep(1)
					drainRX(&leftover)
				}
			}
		}
		if len(in) == 0 {
			continue
		}
		out := cl.Feed(in)
		if len(out) == 0 {
			out = cl.Feed(nil)
		}
		if len(cl.Stdout) > stdoutOff {
			vi.Console(string(cl.Stdout[stdoutOff:]))
			stdoutOff = len(cl.Stdout)
		}
		if len(out) == 0 {
			continue
		}
		if err := pacedSend(conn, out, &leftover); err != nil {
			_ = conn.Close()
			failRun(cl, kexOK)
		}
	}
	if len(cl.Stdout) > stdoutOff {
		vi.Console(string(cl.Stdout[stdoutOff:]))
	}
	_ = conn.Close()
	if cl.Failed() {
		failRun(cl, kexOK)
	}
	if cl.ExitStatus != nil {
		vi.ConsoleLine("ssh: exit-status=" + uitoa(uint(*cl.ExitStatus)))
		vi.ConsoleLine("ssh: bye rc=" + uitoa(uint(*cl.ExitStatus)))
		vi.Exit(int(*cl.ExitStatus))
	}
	vi.ConsoleLine("ssh: bye rc=" + uitoa(sshlib.ExitNoStatus))
	vi.Exit(sshlib.ExitNoStatus)
}

func printHelp() {
	vi.ConsoleLine("GOSSH.ELF - VirelaiOS SSH client (M71j)")
	vi.ConsoleLine("usage: exec GOSSH.ELF [user@]host[:port] [command ...]")
	vi.ConsoleLine("       exec GOSSH.ELF -h   show this help")
	vi.ConsoleLine("  host      numeric IPv4 literal (DNS is a later slice)")
	vi.ConsoleLine("  user      default virelai; port default 22")
	vi.ConsoleLine("  command   one-shot remote exec; omitted = interactive shell")
	vi.ConsoleLine("  pins      SSH/KNOWN_HOSTS; key: TS5 ssh-user-ed25519")
}

func failRun(cl *sshlib.Client, kexOK bool) {
	if kexOK && cl.Stage == "auth" && cl.ErrName != "" {
		vi.ConsoleLine("ssh: auth-error " + cl.ErrName)
	}
	if !kexOK && cl.Stage == "kex" && cl.ErrName != "" {
		vi.ConsoleLine("ssh: kex-error " + cl.ErrName)
	}
	stage := cl.Stage
	if stage == "" {
		stage = "transport"
	}
	vi.ConsoleLine("ssh: fail stage=" + stage + " rc=" + uitoa(uint(cl.ExitCode)))
	vi.Exit(cl.ExitCode)
}

func loadUserSeed() ([32]byte, bool) {
	var zero [32]byte
	var recs [vi.SecretEntriesMax]vi.SecretRecord
	n, r := vi.SecretList(recs[:])
	if r < 0 || n <= 0 {
		return zero, false
	}
	for i := 0; i < n; i++ {
		if recs[i].KeyString() != userSecretName {
			continue
		}
		seed, ok := sshlib.ParseHex32(recs[i].ValString())
		sshlib.Wipe(recs[i].Val[:])
		return seed, ok
	}
	return zero, false
}

func loadPin(host string, port uint16) ([32]byte, bool, bool) {
	var zero [32]byte
	b, r := vi.ReadFileAll(knownHostsPath, 4096)
	if r < 0 {
		return zero, false, false
	}
	pin, found, ok := sshlib.ParseKnownHosts(string(b), host, port)
	return pin, found, ok
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

func drainRX(leftover *[]byte) {
	var buf [vi.TCPPayloadMax]byte
	for {
		n, rc := vi.TCPRecv(buf[:])
		if rc < 0 || n <= 0 {
			return
		}
		*leftover = append(*leftover, buf[:n]...)
	}
}

// recvWait polls tcp_recv (which drains virtio and processes ACKs). Conn.Recv
// probes slot 76 first, which does not drain; a 3-tick RTO then retransmits
// NEWKEYS and the runner leftover-decrypts the duplicate.
func recvWait() ([]byte, int, error) {
	var buf [vi.TCPPayloadMax]byte
	deadline := vi.Nanos() + vi.DefaultRecvBudgetNs
	for polls := 0; polls < 3600; polls++ {
		n, rc := vi.TCPRecv(buf[:])
		if rc < 0 {
			return nil, 0, errString("recv")
		}
		if n > 0 {
			return append([]byte(nil), buf[:n]...), n, nil
		}
		if vi.Nanos() >= deadline {
			return nil, 0, errString("recv timeout")
		}
		vi.Sleep(1)
	}
	return nil, 0, errString("recv timeout")
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
		drainRX(leftover)
		if len(p) == 0 {
			// Do not wait the TX slot after the last byte. kernel tcp
			// rto_ticks is 3 scheduler ticks; a Sleep-wait here
			// retransmits NEWKEYS and the runner leftover-decrypts the
			// duplicate as "bad encrypted length".
			return nil
		}
		deadline := vi.Nanos() + vi.DefaultRecvBudgetNs
		for {
			drainRX(leftover)
			mask, rc := vi.TCPReady()
			if rc < 0 {
				return errString("ready")
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

func uitoa(v uint) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	n := len(buf)
	for v > 0 {
		n--
		buf[n] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[n:])
}
