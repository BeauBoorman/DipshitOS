// GONETRATE.ELF — the M179a (#3147) network throughput fixture: the first
// bench rows for the guest stack plus the host relay (index item b).
//
// It dials the runner's `--net-tcp-respond :relay` endpoint, which forwards
// the byte stream to a real host-side source/sink (netrate.py on
// 127.0.0.1), then moves a FIXED 4 MiB stream in one direction:
//
//   rx — reads the stream to completion, FNV-1a's every byte, and compares
//        each byte against the deterministic pattern it expects (the
//        card's guest-side checksum check);
//   tx — writes the same deterministic pattern (the host sink checks the
//        upload's byte count and checksum).
//
// Why vi.Conn and not vsys.Conn: the guest net stack has NO interrupts —
// virtio_net.net_rx_drain() runs inside net syscalls and the shell idle
// loop, and the advertised receive window is ONE segment (1460 B), so the
// stream advances one segment per guest drain. vsys.Conn's probe is the
// slot-76 readiness query, which deliberately drains nothing — a read
// that misses parks a full ~1 s scheduler tick while the relay sits
// idle, which measured ~560 B/s (ETIMEDOUT after 134,320 B on card run).
// On vi's handle conn every slot-80 op drains RX + polls the socket, so
// this fixture drives the drain itself: ReadyMask probes at ~1 ms
// cadence until the segment is staged, then Recv takes it.
//
// The measurement is vi.Nanos around the transfer loop alone — dial and
// close sit outside the number — and the receipt is
// `gonetrate: rate dir=<rx|tx> bytes=<n> us=<t> kib_s=<r>`, the line
// live-bench's net-rx/net-tx rows read.
package main

import (
	_ "runtime" // the linkname target below (see tools/go/goargs.go)
	_ "unsafe"

	"virelai/vi"
)

//go:linkname args runtime.VirelaiArgs
func args() []string

const (
	// transferSize is the pinned stream both directions move: the host
	// source serves exactly this many bytes and the host sink counts to
	// exactly this many. 4 MiB is large enough that segment cadence —
	// not syscall overhead — dominates the measured rate.
	transferSize = 4 * 1024 * 1024

	// patternSeed feeds the xorshift64* payload stream netrate.py
	// reproduces on the host byte-for-byte, so the checksum is a real
	// comparison and not a constant both sides could drift away from.
	patternSeed = uint64(0x9e3779b97f4a7c15)

	fnvOffset = uint64(0xcbf29ce484222325)
	fnvPrime  = uint64(0x100000001b3)

	// pollNs is the drain cadence between idle probes — slot-80 ops drain
	// the device on every call, so 1 ms polls keep the ACK engine hot
	// without busy-spinning a whole core at syscall rate.
	pollNs = uint64(1_000_000)
)

// pattern is the deterministic payload stream, emitted one byte at a time
// from a xorshift64* word generator (8 bytes little-endian per step).
// netrate.py implements the identical generator; tx streams what it makes,
// rx checks every received byte against what it should have been.
type pattern struct {
	s    uint64
	word uint64
	have int
}

func (p *pattern) next() byte {
	if p.have == 0 {
		p.s ^= p.s >> 12
		p.s ^= p.s << 25
		p.s ^= p.s >> 27
		p.word = p.s * 2685821657736338717
		p.have = 8
	}
	b := byte(p.word)
	p.word >>= 8
	p.have--
	return b
}

func main() {
	a := args()
	if len(a) < 3 {
		fail("usage: exec GONETRATE.ELF <rx|tx> <port>")
	}
	dir := a[1]
	port := atoi(a[2])
	if dir != "rx" && dir != "tx" {
		fail("bad direction " + dir + " (want rx or tx)")
	}
	if port <= 0 || port > 65535 {
		fail("bad port " + a[2])
	}

	conn, err := vi.Dial("10.0.0.2", uint16(port))
	if err != nil {
		fail("dial " + err.Error())
	}
	println("gonetrate: connected dir=" + dir)

	if dir == "rx" {
		runRx(conn)
	} else {
		runTx(conn)
	}
}

// runRx reads the fixed stream end to end, hashing and pattern-checking
// every byte. One absolute deadline bounds the whole download — a source
// that goes dark mid-stream fails closed, never parks the bench.
func runRx(conn *vi.Conn) {
	conn.SetRecvDeadline(240_000_000_000) // 240 s covers a stalled stream
	buf := make([]byte, vi.TCPPayloadMax)
	pat := pattern{s: patternSeed}
	var bytes int64
	hash := fnvOffset
	mismatch := false
	t0 := vi.Nanos()
	for bytes < transferSize {
		n, err := recvOnce(conn, buf)
		if err != nil {
			conn.Close()
			fail("read " + err.Error() + " after " + vi.Itoa64(bytes))
		}
		for i := 0; i < n; i++ {
			b := buf[i]
			hash ^= uint64(b)
			hash *= fnvPrime
			if b != pat.next() {
				mismatch = true
			}
		}
		bytes += int64(n)
	}
	nanos := vi.Nanos() - t0
	conn.Close()

	println("gonetrate: fnv 0x" + hex64(hash))
	if bytes != transferSize {
		fail("short stream " + vi.Itoa64(bytes))
	}
	if mismatch {
		fail("cksum mismatch — received bytes diverged from the pattern")
	}
	println("gonetrate: cksum ok")
	report("rx", bytes, nanos)
}

// recvOnce is the drain-driven read: ReadyMask is a slot-80 probe that
// drains the device on every call, so polling it keeps segments (and the
// guest's ACKs) moving at syscall cadence instead of the ~1 s scheduler-
// tick park a raw Conn.Recv pays on every empty probe.
func recvOnce(conn *vi.Conn, buf []byte) (int, error) {
	for {
		mask, err := conn.ReadyMask()
		if err != nil {
			return 0, err
		}
		if mask&1 != 0 { // readyRead
			return conn.Recv(buf)
		}
		vi.SleepNs(pollNs)
	}
}

// runTx writes the fixed stream end to end in payload_max segments,
// hashing the bytes as they are produced so the host sink's checksum is a
// comparison of what was ACTUALLY put on the wire, not of a constant.
// Between sends a probe + short sleep lets the relay's ACK land and free
// the kernel's one-in-flight TX slot, so Send almost never pays its
// internal 1-tick park.
func runTx(conn *vi.Conn) {
	buf := make([]byte, vi.TCPPayloadMax)
	pat := pattern{s: patternSeed}
	var bytes int64
	hash := fnvOffset
	t0 := vi.Nanos()
	for bytes < transferSize {
		want := int64(transferSize) - bytes
		if want > vi.TCPPayloadMax {
			want = vi.TCPPayloadMax
		}
		for i := int64(0); i < want; i++ {
			b := pat.next()
			buf[i] = b
			hash ^= uint64(b)
			hash *= fnvPrime
		}
		_, _ = conn.ReadyMask() // drain: pulls the previous segment's ACK
		vi.SleepNs(pollNs)
		n, err := conn.Send(buf[:want])
		if err != nil {
			conn.Close()
			fail("write " + err.Error() + " after " + vi.Itoa64(bytes))
		}
		bytes += int64(n)
	}
	nanos := vi.Nanos() - t0
	conn.Close()

	println("gonetrate: fnv 0x" + hex64(hash))
	report("tx", bytes, nanos)
}

// report prints the corpus row's metric line and the run's done marker.
// The rate line is ONE string printed TWICE: the kernel's own chatter can
// interleave mid-line on the serial log (observed on-card: a torn
// `gonetrate: rate dir=rx` with no numbers), and the bench's last-match
// regex needs at least one intact copy.
func report(dir string, bytes, nanos int64) {
	kib := bytes * 1_000_000_000 / 1024 / nanos
	line := "gonetrate: rate dir=" + dir +
		" bytes=" + vi.Itoa64(bytes) +
		" us=" + vi.Itoa64(nanos/1000) +
		" kib_s=" + vi.Itoa64(kib)
	println(line)
	println(line)
	println("gonetrate: GONETRATE OK")
}

// fail prints one honest reason and exits non-zero, so a broken
// measurement is a failed run rather than a green one with no numbers.
func fail(reason string) {
	println("gonetrate: FAIL " + reason)
	vi.Exit(1)
}

// atoi parses a decimal port (hand-rolled — strconv is not reachable from
// a GOOS=virelai build).
func atoi(s string) int {
	v := 0
	if len(s) == 0 {
		return -1
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return -1
		}
		v = v*10 + int(c-'0')
	}
	return v
}

// hex64 formats v as 16 lowercase hex digits (the hash's wire form).
func hex64(v uint64) string {
	const digits = "0123456789abcdef"
	var buf [16]byte
	for i := 15; i >= 0; i-- {
		buf[i] = digits[v&0xf]
		v >>= 4
	}
	return string(buf[:])
}
