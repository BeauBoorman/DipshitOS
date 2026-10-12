// The drain-driven transport. The kernel's TCP is polled: the slot-76
// readiness probe never drains the NIC — only slot-32 tcp_recv (and the
// other net syscalls) pulls one frame and flushes queued control. A
// session parked on TCPReady alone starves the wire: the ONE armed RX
// buffer stays occupied, later frames drop at the device, and a queued
// SYN-ACK/ACK/FIN only leaves when some other task happens to drain
// (gotabwm's rfbStream documents the same contract for its listener).
// Every wait here therefore calls TCPRecv first — each call is a drain —
// and yields between polls so the rest of the system keeps running.
package main

import (
	"errors"

	"virelai/vi"
)

var (
	tcpRecvFn  = vi.TCPRecv
	tcpSendFn  = vi.TCPSend
	tcpReadyFn = vi.TCPReady
	yieldFn    = vi.Yield
	nanosFn    = vi.Nanos
)

// errTimeout is the deadline verdict under the kernel's errno spelling —
// readLine maps it by name, like a real ETIMEDOUT.
var errTimeout = errors.New("ETIMEDOUT")

// relistenSpins bounds the post-close listen retry: a closed session can
// leave the singleton in fin_sent — the hermetic peer ACKs our FIN but
// never sends one of its own, so only the poll_rto abort (10 retries at
// 3 ticks, driven by the shell idle) releases it to .listen. 80 ticks
// covers that with margin; every spin drains so a late RST/FIN+ACK frees
// it sooner.
const relistenSpins = 80

// errFromRc turns a negative syscall result into an error carrying the
// kernel's errno name. EAGAIN is the socket-unowned verdict — the Conn's
// closed contract upstream.
func errFromRc(rc int64) error {
	if -rc == vi.ErrEAGAIN {
		return vi.ErrConnClosed
	}
	name := vi.ErrnoName(rc)
	if name == "" {
		name = "EIO"
	}
	return errors.New(name)
}

// drainConn is the session's connIO over the TCP singleton. Deadline
// semantics match vi.Conn (an absolute Nanos deadline; unset means the
// default budget). pre holds payload a drain pulled ahead of the next
// read — the handshake's completing ACK can already carry the peer's
// first segment, and a drain must never drop it.
type drainConn struct {
	pre        []byte
	deadlineAt int64
	peerGone   bool
}

func (c *drainConn) SetRecvDeadline(ns int64) {
	if ns <= 0 {
		c.deadlineAt = 0
		return
	}
	c.deadlineAt = nanosFn() + ns
}

func (c *drainConn) Recv(p []byte) (int, error) {
	if c.peerGone {
		return 0, vi.ErrPeerGone
	}
	max := len(p)
	if max > vi.TCPPayloadMax {
		max = vi.TCPPayloadMax
	}
	if max == 0 {
		return 0, nil
	}
	if len(c.pre) > 0 {
		n := copy(p[:max], c.pre)
		c.pre = append(c.pre[:0], c.pre[n:]...)
		return n, nil
	}
	deadline := c.deadlineAt
	if deadline == 0 {
		deadline = nanosFn() + vi.DefaultRecvBudgetNs
	}
	for {
		// The drain: one inbound frame and one queued control segment
		// move on every call — the peer's ACK clears tx_pending, our
		// ACK/FIN leaves, and the armed RX buffer stays empty.
		n, rc := tcpRecvFn(p[:max])
		if rc < 0 {
			return 0, errFromRc(rc)
		}
		if n > 0 {
			return n, nil
		}
		mask, rc := tcpReadyFn()
		if rc < 0 {
			return 0, errFromRc(rc)
		}
		// readable-but-empty is the FIN/RST — fail closed (the vi.Conn
		// contract).
		if mask&1 != 0 {
			c.peerGone = true
			return 0, vi.ErrPeerGone
		}
		if nanosFn() >= deadline {
			return 0, errTimeout
		}
		yieldFn()
	}
}

func (c *drainConn) Send(p []byte) (int, error) {
	if c.peerGone {
		return 0, vi.ErrPeerGone
	}
	sent := 0
	deadline := nanosFn() + vi.DefaultRecvBudgetNs
	for sent < len(p) {
		// The drain frees the pending segment: writable (mask bit 1) is
		// established + ACKed — one segment in flight, the kernel's bound.
		var scrap [vi.TCPPayloadMax]byte
		n, rc := tcpRecvFn(scrap[:])
		if rc < 0 {
			return sent, errFromRc(rc)
		}
		if n > 0 {
			if len(c.pre)+n > pendingMax {
				c.peerGone = true
				return sent, vi.ErrPeerGone
			}
			c.pre = append(c.pre, scrap[:n]...)
		}
		mask, rc := tcpReadyFn()
		if rc < 0 {
			return sent, errFromRc(rc)
		}
		if mask&2 == 0 {
			// readable-but-empty while unwritable: the peer went away.
			if mask&1 != 0 && n == 0 {
				c.peerGone = true
				return sent, vi.ErrPeerGone
			}
			if nanosFn() >= deadline {
				return sent, errTimeout
			}
			yieldFn()
			continue
		}
		take := len(p) - sent
		if take > vi.TCPPayloadMax {
			take = vi.TCPPayloadMax
		}
		n2, rc := tcpSendFn(p[sent : sent+take])
		if rc < 0 {
			return sent, errFromRc(rc)
		}
		if n2 == 0 {
			return sent, errors.New("EINVAL")
		}
		sent += n2
	}
	return sent, nil
}

// waitEstablished pumps the accept path until the singleton goes live:
// each drain moves one inbound frame (the SYN to syn_received, the
// completing ACK to established) and flushes the queued SYN-ACK, so the
// handshake runs at syscall rate. Payload the completing exchange
// already carried is banked into pre for the session's first read.
func waitEstablished(pre *[]byte) error {
	deadline := nanosFn() + vi.DefaultRecvBudgetNs
	for {
		var scrap [vi.TCPPayloadMax]byte
		n, rc := tcpRecvFn(scrap[:])
		if rc < 0 {
			return errFromRc(rc)
		}
		if n > 0 {
			*pre = append(*pre, scrap[:n]...)
			if len(*pre) > pendingMax {
				return errors.New("ENOSPC")
			}
		}
		mask, rc := tcpReadyFn()
		if rc < 0 {
			return errFromRc(rc)
		}
		if mask&3 != 0 {
			return nil
		}
		if nanosFn() >= deadline {
			return errTimeout
		}
		yieldFn()
	}
}

// zombieDrain is one relisten wait step: the post-close singleton may sit
// in fin_sent until the retransmission abort frees it — keep the NIC
// drained (a late RST/FIN+ACK releases it early) and pace one tick.
func zombieDrain() {
	var scrap [vi.TCPPayloadMax]byte
	_, _ = tcpRecvFn(scrap[:])
	sleepFn(1)
}

// peerGoneTicks / peerDrainBurst bound waitPeerGone: ticks pace the wait
// in real seconds while the burst keeps the RX buffer cycling between
// them, so a client that never closes costs at most ~peerGoneTicks s.
const (
	peerGoneTicks  = 8
	peerDrainBurst = 512
)

// waitPeerGone drains until the peer's close lands (FIN or RST — the
// readable-but-empty verdict) or the bound lapses. It runs between the
// session's last send and Close: a guest-first FIN leaves the kernel
// waiting on a FIN+ACK this transport's peer never sends (a ~30-tick
// zombie), while a peer close consumed while still established releases
// the socket to .listen inside the Close call itself.
func waitPeerGone() {
	var scrap [vi.TCPPayloadMax]byte
	for tick := 0; tick < peerGoneTicks; tick++ {
		for i := 0; i < peerDrainBurst; i++ {
			n, rc := tcpRecvFn(scrap[:])
			if rc < 0 {
				return
			}
			mask, rc := tcpReadyFn()
			if rc < 0 {
				return
			}
			if mask&1 != 0 && n == 0 {
				return
			}
			yieldFn()
		}
		sleepFn(1)
	}
}
