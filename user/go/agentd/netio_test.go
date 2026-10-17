package main

// Issue #2436: bit0 of the legacy ready mask is "a read outcome is
// pending" — queued bytes OR a peer close. drainConn's "readable-but-
// empty after a 0-recv = peer gone" verdict is only honest when the
// empty read and the probe see the same socket: a segment that lands
// between the two syscalls must re-read once before the session is
// declared dead.

import (
	"testing"

	"virelai/vi"
)

// netioSeam scripts the socket syscalls the drain pumps.
type netioSeam struct {
	recv []func(p []byte) (int, int64)
	send []func(p []byte) (int, int64)
	rdy  []func() (int64, int64)
}

func (s *netioSeam) install(t *testing.T) {
	t.Helper()
	oldRecv, oldSend, oldReady := tcpRecvFn, tcpSendFn, tcpReadyFn
	oldYield, oldNanos := yieldFn, nanosFn
	t.Cleanup(func() {
		tcpRecvFn, tcpSendFn, tcpReadyFn = oldRecv, oldSend, oldReady
		yieldFn, nanosFn = oldYield, oldNanos
	})
	tcpRecvFn = func(p []byte) (int, int64) {
		if len(s.recv) == 0 {
			return 0, 0
		}
		f := s.recv[0]
		s.recv = s.recv[1:]
		return f(p)
	}
	tcpSendFn = func(p []byte) (int, int64) {
		if len(s.send) == 0 {
			return len(p), 0
		}
		f := s.send[0]
		s.send = s.send[1:]
		return f(p)
	}
	tcpReadyFn = func() (int64, int64) {
		if len(s.rdy) == 0 {
			return 0, 0
		}
		f := s.rdy[0]
		s.rdy = s.rdy[1:]
		return f()
	}
	yieldFn = func() {}
	now := int64(0)
	nanosFn = func() int64 { now += 1; return now }
}

func recvBytes(b []byte) func(p []byte) (int, int64) {
	return func(p []byte) (int, int64) {
		n := copy(p, b)
		return n, 0
	}
}

// A data segment that lands between the empty drain and the probe sets
// bit0 exactly like a FIN would. The re-read must recover it as data —
// the session lives.
func TestRecvDataRacedProbeServesBytes(t *testing.T) {
	s := &netioSeam{
		recv: []func(p []byte) (int, int64){
			func(p []byte) (int, int64) { return 0, 0 }, // empty drain
			recvBytes([]byte("{\"id\":24")),             // raced segment
		},
		rdy: []func() (int64, int64){
			func() (int64, int64) { return 1, 0 }, // bit0: "something" pending
		},
	}
	s.install(t)
	var c drainConn
	got := make([]byte, vi.TCPPayloadMax)
	n, err := c.Recv(got)
	if err != nil {
		t.Fatalf("Recv err = %v, want data", err)
	}
	if n == 0 {
		t.Fatal("Recv returned 0, want the raced bytes")
	}
}

// A genuine close is bit0 PLUS an empty re-read — the verdict stands.
func TestRecvGoneAfterConfirmingEmptyDrain(t *testing.T) {
	s := &netioSeam{
		recv: []func(p []byte) (int, int64){
			func(p []byte) (int, int64) { return 0, 0 }, // empty drain
			func(p []byte) (int, int64) { return 0, 0 }, // honest empty re-read
		},
		rdy: []func() (int64, int64){
			func() (int64, int64) { return 1, 0 }, // FIN/terminal readable
		},
	}
	s.install(t)
	var c drainConn
	got := make([]byte, vi.TCPPayloadMax)
	n, err := c.Recv(got)
	if err != vi.ErrPeerGone {
		t.Fatalf("Recv err = %v, want ErrPeerGone", err)
	}
	if n != 0 {
		t.Fatalf("Recv n = %d, want 0", n)
	}
}

// The send-side wait sees the same race: unwritable + a segment landing
// mid-pair must bank the bytes, not kill the stream.
func TestSendDataRacedProbeBanksAndSends(t *testing.T) {
	var sentCalls int
	s := &netioSeam{
		recv: []func(p []byte) (int, int64){
			func(p []byte) (int, int64) { return 0, 0 }, // empty drain
			recvBytes([]byte("stale")),                  // raced segment
		},
		rdy: []func() (int64, int64){
			func() (int64, int64) { return 1, 0 }, // unwritable + bit0
			func() (int64, int64) { return 2, 0 }, // writable now
		},
		send: []func(p []byte) (int, int64){
			func(p []byte) (int, int64) { sentCalls++; return len(p), 0 },
		},
	}
	s.install(t)
	var c drainConn
	n, err := c.Send([]byte("{\"ok\":true}\n"))
	if err != nil {
		t.Fatalf("Send err = %v", err)
	}
	if n == 0 || sentCalls == 0 {
		t.Fatalf("Send n = %d sentCalls = %d", n, sentCalls)
	}
	if string(c.pre) != "stale" {
		t.Fatalf("pre = %q, want the raced bytes banked", string(c.pre))
	}
}

// An unwritable conn whose confirming drain stays empty is a real close.
func TestSendGoneAfterConfirmingEmptyDrain(t *testing.T) {
	s := &netioSeam{
		recv: []func(p []byte) (int, int64){
			func(p []byte) (int, int64) { return 0, 0 },
			func(p []byte) (int, int64) { return 0, 0 },
		},
		rdy: []func() (int64, int64){
			func() (int64, int64) { return 1, 0 }, // unwritable + bit0
		},
	}
	s.install(t)
	var c drainConn
	_, err := c.Send([]byte("x"))
	if err != vi.ErrPeerGone {
		t.Fatalf("Send err = %v, want ErrPeerGone", err)
	}
}
