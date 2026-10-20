package main

// Host-only: drives the real session loop over a real socket pair
// (net.Pipe + a scripted in-process fixture), which the fakeConn tests
// cannot — actual byte framing, partial reads, and peer-close detection
// all go through the true Read path. `net` never links into the guest
// binary (test files are host-only).

import (
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

// netConn adapts net.Conn onto WireConn for the host test.
type netConn struct{ c net.Conn }

func (n netConn) Read(p []byte) (int, error) {
	r, err := n.c.Read(p)
	if err == io.EOF {
		return r, errFakeEOF
	}
	if err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return r, errFakeTimeout
		}
	}
	return r, err
}

func (n netConn) Write(p []byte) (int, error) { return n.c.Write(p) }
func (n netConn) Close() error                { return n.c.Close() }
func (n netConn) SetReadDeadline(at int64) {
	_ = n.c.SetReadDeadline(time.Unix(0, at))
}

// fixtureServer plays the card leg: register → JOIN confirm + hello →
// hard close on conn 1; register → JOIN confirm + marker on conn 2.
// Returns the observed transcript when done.
func fixtureServer(t *testing.T, conns int, marker string) (addr string, transcript *strings.Builder) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	var sb strings.Builder
	go func() {
		defer ln.Close()
		for i := 0; i < conns; i++ {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn, idx int) {
				defer c.Close()
				buf := make([]byte, 4096)
				var pending []byte
				nick, user := "", false
				readLine := func() (string, bool) {
					for {
						if k := indexOfByte(pending, '\n'); k >= 0 {
							l := string(pending[:k])
							pending = pending[k+1:]
							return strings.TrimSuffix(l, "\r"), true
						}
						n, _ := c.Read(buf)
						if n <= 0 {
							return "", false
						}
						pending = append(pending, buf[:n]...)
					}
				}
				_ = c.SetReadDeadline(time.Now().Add(15 * time.Second))
				for {
					line, ok := readLine()
					if !ok {
						return
					}
					sb.WriteString("rx " + line + "\n")
					f := strings.Fields(line)
					if len(f) == 0 {
						continue
					}
					switch f[0] {
					case "NICK":
						nick = f[1]
					case "USER":
						user = true
					case "PING":
						io.WriteString(c, ":srv PONG srv\r\n")
					case "JOIN":
						ch := strings.TrimPrefix(f[1], ":")
						io.WriteString(c, ":"+nick+"!u@h JOIN "+ch+"\r\n")
						if idx == 0 {
							io.WriteString(c, ":alice!u@h PRIVMSG "+ch+" :first-hello\r\n")
							time.Sleep(50 * time.Millisecond)
							return // hard close = the drop
						}
						io.WriteString(c, ":alice!u@h PRIVMSG "+ch+" :"+marker+"\r\n")
					case "QUIT":
						return
					}
					if nick != "" && user {
						io.WriteString(c, ":srv 001 "+nick+" :welcome\r\n")
						nick, user = nick+"!", false // once
					}
				}
			}(conn, i)
		}
	}()
	return ln.Addr().String(), &sb
}

func indexOfByte(b []byte, c byte) int {
	for i, x := range b {
		if x == c {
			return i
		}
	}
	return -1
}

func TestSessionOverRealSocket(t *testing.T) {
	addr, transcript := fixtureServer(t, 2, "REJOIN-MARKER")
	host, port := splitHostPort(t, addr)

	cfg := baseCfg()
	cfg.Host = host
	cfg.Port = port
	cfg.Reconnect = true
	cfg.MaxRetries = 1
	cfg.BackoffBase = 10 * 1e6 // 10 ms — real sleeps, still fast

	var mu = make(chan Event, 256)
	c := NewClient(cfg, func() (WireConn, error) {
		nc, err := net.DialTimeout("tcp", addr, 5*time.Second)
		if err != nil {
			return nil, err
		}
		return netConn{nc}, nil
	}, func(e Event) { mu <- e })

	done := make(chan error, 1)
	go func() { done <- c.Run() }()

	// Collect until the post-rejoin marker's backlog entry arrives.
	deadline := time.After(20 * time.Second)
	gotRejoin, gotMarker := false, false
	for !gotMarker {
		select {
		case e := <-mu:
			if e.Kind == EvRejoined {
				gotRejoin = true
			}
			if e.Kind == EvEntry && e.Entry.Text == "REJOIN-MARKER" {
				gotMarker = true
			}
		case <-deadline:
			t.Fatalf("timed out; rejoin=%v transcript=%s", gotRejoin, transcript.String())
		}
	}
	_ = c.Close()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after Close")
	}
	if !gotRejoin {
		t.Fatal("no EvRejoined over a real socket drop/reconnect")
	}
}

func splitHostPort(t *testing.T, addr string) (string, uint16) {
	i := strings.LastIndexByte(addr, ':')
	if i < 0 {
		t.Fatalf("addr %q", addr)
	}
	n, ok := parseUint(addr[i+1:])
	if !ok {
		t.Fatalf("port %q", addr[i+1:])
	}
	return addr[:i], uint16(n)
}
