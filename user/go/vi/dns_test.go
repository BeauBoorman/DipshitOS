package vi

import (
	"errors"
	"testing"
	"unsafe"
)

// hookBytes rebuilds a byte argument the fake kernel received. The pointer
// is the one bytePtr handed the seam (still live inside the call), so this
// is the same contract the guest assembly reads through — test-only.
func hookBytes(a0, a1 uintptr) []byte {
	if a0 == 0 || a1 == 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(a0)), a1)
}

// resetDNSCacheForTest drains the per-process TTL cache between tests —
// the cache is process-global state exactly like the kernel's listen
// table the fake models.
func resetDNSCacheForTest() {
	dnsCacheMu.Lock()
	defer dnsCacheMu.Unlock()
	dnsCache = [dnsCacheSlots]dnsCacheEntry{}
}

// The DNS host fake for the OWNED seam: a scripted kernel that models the
// listen table's ownership (bind/close per port), answers recv_from from a
// caller-provided script, and feeds a deterministic counter through
// getrandom so port draws and query IDs are reproducible in the test.
// send_from arrives on the six-arg hook; every other slot on the four-arg
// one — both are installed by startDNSFake.
type dnsFake struct {
	bound       map[uint16]bool // ports the listen table holds
	listenCalls int
	sendCalls   int
	recvCalls   int
	closeCalls  int
	randCalls   int
	sleeps      int
	other       int
	listenPort  uintptr
	closePort   uintptr
	sentIP      uint32
	sentDstPort uintptr
	sentSrcPort uintptr
	sentQuery   []byte
	sentQTypes  []uint16 // the QTYPE of every query sent, in order
	randSeq     uint32
	// now stamps every seam event with a sequence number so a test can pin
	// ORDER (e.g. the reply port is bound before the query goes out), not
	// just counts.
	listenSeq int
	sendSeq   int
	recvSeq   int
	closeSeq  int
	now       int
	// refuseBinds makes the next N binds return EINVAL (an ephemeral
	// collision) before honoring them; refuseENOSPC makes every bind a
	// full table.
	refuseBinds  int
	refuseENOSPC bool
	// recvScript maps (port, 1-based recv call on that port) to the
	// datagram to deliver — the slot-85 shape, 4-byte src-IP prefix +
	// 8-byte UDP header + payload. A nil script always returns 0.
	recvScript func(port uint16, call int) []byte
	recvPer    map[uint16]int
}

func (f *dnsFake) hook(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	switch num {
	case SlotGetRandom:
		f.randCalls++
		f.randSeq++
		buf := hookBytes(a0, a1)
		for i := range buf {
			buf[i] = byte(f.randSeq >> (i % 4 * 8))
			buf[i] ^= byte(i*37 + int(f.randSeq))
		}
		return int64(len(buf))
	case SlotUDPListen:
		f.listenCalls++
		f.listenPort = a0
		f.now++
		f.listenSeq = f.now
		if f.refuseENOSPC {
			return -ErrENOSPC
		}
		if f.refuseBinds > 0 {
			f.refuseBinds--
			return -ErrEINVAL
		}
		if f.bound[uint16(a0)] {
			return -ErrEINVAL
		}
		f.bound[uint16(a0)] = true
		return 0
	case SlotUDPRecvFrom:
		f.recvCalls++
		f.now++
		f.recvSeq = f.now
		port := uint16(a0)
		if !f.bound[port] {
			return -ErrEINVAL
		}
		f.recvPer[port]++
		if f.recvScript == nil {
			return 0
		}
		dgram := f.recvScript(port, f.recvPer[port])
		if dgram == nil {
			return 0
		}
		// Slot 85 args: (port, buf, max) — the buffer is a1, clamped by a2.
		take := len(dgram)
		if uintptr(take) > a2 {
			take = int(a2)
		}
		copy(hookBytes(a1, uintptr(take)), dgram[:take])
		return int64(take)
	case SlotUDPClose:
		f.closeCalls++
		f.closePort = a0
		f.now++
		f.closeSeq = f.now
		if !f.bound[uint16(a0)] {
			return -ErrEINVAL
		}
		delete(f.bound, uint16(a0))
		return 0
	case SlotSleep:
		f.sleeps++
		return 0
	}
	f.other++
	return -ErrENOSYS
}

func (f *dnsFake) hook6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
	switch num {
	case SlotUDPSendFrom:
		f.sendCalls++
		f.sentIP = uint32(a0)
		f.sentDstPort = a1
		f.sentSrcPort = a2
		f.sentQuery = hookBytes(a3, a4)
		f.sentQTypes = append(f.sentQTypes, queryQType(f.sentQuery))
		f.now++
		f.sendSeq = f.now
		// The kernel requires src_port to be bound by the caller — the
		// fake enforces the same rule so a send-from-another-port bug is
		// a test failure, not a silent pass.
		if !f.bound[uint16(a2)] {
			return -ErrEINVAL
		}
		return int64(a4)
	}
	return -ErrENOSYS
}

func startDNSFake(t *testing.T) *dnsFake {
	t.Helper()
	f := &dnsFake{bound: map[uint16]bool{}, recvPer: map[uint16]int{}}
	prev := SetSyscallHookForTest(f.hook)
	prev6 := SetSyscallHook6ForTest(f.hook6)
	t.Cleanup(func() { SetSyscallHookForTest(prev) })
	t.Cleanup(func() { SetSyscallHook6ForTest(prev6) })
	t.Cleanup(resetDNSCacheForTest)
	return f
}

// udpDgramFrom wraps a DNS message in the slot-85 shape the kernel hands
// recv_from: the sender's IPv4, then the 8-byte UDP header (src port
// first — the field the client filters on), then the payload.
func udpDgramFrom(srcIP [4]byte, srcPort, dstPort uint16, msg []byte) []byte {
	d := make([]byte, 4+8+len(msg))
	copy(d[0:4], srcIP[:])
	d[4] = byte(srcPort >> 8)
	d[5] = byte(srcPort)
	d[6] = byte(dstPort >> 8)
	d[7] = byte(dstPort)
	n := 8 + len(msg)
	d[8] = byte(n >> 8)
	d[9] = byte(n)
	copy(d[12:], msg)
	return d
}

var dnsTestServer = [4]byte{10, 0, 0, 2}

// dgram is the test shorthand: a reply-shaped datagram from the server
// the query went to (captured in sentIP), on the resolver port. The
// destination port does not matter to the parse — the kernel delivered
// it to the bound ring — but a correct one keeps the fixture honest.
func dgram(f *dnsFake, msg []byte) []byte {
	src := [4]byte{byte(f.sentIP >> 24), byte(f.sentIP >> 16), byte(f.sentIP >> 8), byte(f.sentIP)}
	return udpDgramFrom(src, DNSPort, uint16(f.sentSrcPort), msg)
}

// dnsReplyFor mirrors the runner's buildDnsReply (host/vm-runner): echoed
// question, one answer with a compression pointer to offset 12, one A
// record with TTL 300. The reply echoes the query's ID.
func dnsReplyFor(query []byte, ip [4]byte) []byte {
	msg := make([]byte, 0, len(query)+16)
	msg = append(msg, query[0], query[1], 0x81, 0x80,
		0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00)
	msg = append(msg, query[12:]...) // the echoed question
	msg = append(msg, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01,
		0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, ip[0], ip[1], ip[2], ip[3])
	return msg
}

// queryQType is the QTYPE a captured query asked — the two bytes
// before the trailing QCLASS.
func queryQType(query []byte) uint16 {
	return uint16(query[len(query)-4])<<8 | uint16(query[len(query)-3])
}

// dnsNODATA is the empty answer: header + echoed question, ANCOUNT=0 —
// the reply an AAAA-only name gives an A query (and vice versa).
func dnsNODATA(query []byte) []byte {
	msg := make([]byte, 0, len(query))
	msg = append(msg, query[0], query[1], 0x81, 0x80,
		0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
	msg = append(msg, query[12:]...)
	return msg
}

// dnsReplyTTL is dnsReplyFor with a caller-chosen TTL (the cache-clamp
// fixture): the A record's TTL sits 6 bytes into the 16-byte answer block
// that follows the echoed question at len(query).
func dnsReplyTTL(query []byte, ip [4]byte, ttl uint32) []byte {
	msg := dnsReplyFor(query, ip)
	aoff := len(query)
	msg[aoff+6] = byte(ttl >> 24)
	msg[aoff+7] = byte(ttl >> 16)
	msg[aoff+8] = byte(ttl >> 8)
	msg[aoff+9] = byte(ttl)
	return msg
}

// dnsReplyAAAA is dnsReplyFor for an AAAA query: type 28, rdlen 16,
// TTL 300.
func dnsReplyAAAA(query []byte, ip [16]byte) []byte {
	msg := make([]byte, 0, len(query)+28)
	msg = append(msg, query[0], query[1], 0x81, 0x80,
		0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00)
	msg = append(msg, query[12:]...)
	msg = append(msg, 0xC0, 0x0C, 0x00, 0x1C, 0x00, 0x01,
		0x00, 0x00, 0x01, 0x2C, 0x00, 0x10)
	msg = append(msg, ip[:]...)
	return msg
}

// dnsReplyMulti is a three-answer response: an A for first, a CNAME-style
// skip record (type 5 with a one-label rdata), and an A for second —
// ANCOUNT=3 so the walker must cover records it does not use.
func dnsReplyMulti(query []byte, first, second [4]byte) []byte {
	msg := make([]byte, 0, len(query)+40)
	msg = append(msg, query[0], query[1], 0x81, 0x80,
		0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00)
	msg = append(msg, query[12:]...)
	msg = append(msg, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04,
		first[0], first[1], first[2], first[3])
	msg = append(msg, 0xC0, 0x0C, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x02, 0xC0, 0x0C)
	msg = append(msg, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x04,
		second[0], second[1], second[2], second[3])
	return msg
}

func TestResolve_QueryFraming(t *testing.T) {
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyFor(f.sentQuery, [4]byte{93, 184, 216, 34}))
	}
	res, err := Resolve("myhost.local", dnsTestServer, DNSQueryA, 0)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if len(res.Addrs) != 1 || res.Addrs[0].V6 || res.Addrs[0].IPv4 != [4]byte{93, 184, 216, 34} {
		t.Fatalf("resolved %+v, want 93.184.216.34", res.Addrs)
	}
	if res.Cached || res.Ignored != 0 || res.Answers != 1 {
		t.Fatalf("result = %+v, want answers=1 ignored=0 uncached", res)
	}
	if res.TTLNs != 300_000_000_000 {
		t.Fatalf("TTL = %d, want 300s", res.TTLNs)
	}
	// The reply port is bound BEFORE the query goes out, and released
	// after — the ephemeral transaction, pinned by sequence.
	if f.listenCalls != 1 {
		t.Fatalf("listen = %d calls, want 1", f.listenCalls)
	}
	port := uint16(f.listenPort)
	if int(port) < dnsEphemeralLo || int(port) >= dnsEphemeralLo+dnsEphemeralSpan {
		t.Fatalf("bound port %d outside the ephemeral range", port)
	}
	if f.listenSeq == 0 || f.sendSeq == 0 || f.listenSeq >= f.sendSeq {
		t.Fatalf("event order = listen#%d, send#%d, want listen before send",
			f.listenSeq, f.sendSeq)
	}
	if f.closeCalls != 1 || uint16(f.closePort) != port || f.closeSeq <= f.sendSeq {
		t.Fatalf("close = %d calls on port %d seq %d, want the bound port released after send",
			f.closeCalls, f.closePort, f.closeSeq)
	}
	if f.sentIP != 0x0a000002 || f.sentDstPort != DNSPort || uint16(f.sentSrcPort) != port {
		t.Fatalf("send = %08x:%d from %d, want 0a000002:53 from the bound port",
			f.sentIP, f.sentDstPort, f.sentSrcPort)
	}
	// Header: RD set, one question, CSPRNG ID (two Resolves must not share it).
	if f.sentQuery[2] != 0x01 || f.sentQuery[3] != 0x00 {
		t.Fatalf("query flags = %02x%02x, want RD (0x0100)", f.sentQuery[2], f.sentQuery[3])
	}
	if f.sentQuery[4] != 0 || f.sentQuery[5] != 1 {
		t.Fatalf("QDCOUNT = %d, want 1", uint16(f.sentQuery[4])<<8|uint16(f.sentQuery[5]))
	}
	if f.randCalls < 2 {
		t.Fatalf("getrandom called %d times — the port draw and the query ID both ride it", f.randCalls)
	}
	// QNAME for myhost.local: \x06myhost\x05local\x00, then A/IN.
	qname := []byte{6, 'm', 'y', 'h', 'o', 's', 't', 5, 'l', 'o', 'c', 'a', 'l', 0}
	want := append([]byte{f.sentQuery[0], f.sentQuery[1], 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}, qname...)
	want = append(want, 0x00, 0x01, 0x00, 0x01)
	if string(f.sentQuery) != string(want) {
		t.Fatalf("query = % x, want % x", f.sentQuery, want)
	}
}

func TestResolve_QueryIDsDifferAcrossTransactions(t *testing.T) {
	f := startDNSFake(t)
	var ids []uint16
	// Each transaction's query is captured at send; the ID is its first
	// two bytes. Cache-bust by resolving different names.
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyFor(f.sentQuery, [4]byte{10, 0, 0, 2}))
	}
	for _, name := range []string{"a.first", "b.second", "c.third"} {
		if _, err := Resolve(name, dnsTestServer, DNSQueryA, 0); err != nil {
			t.Fatalf("Resolve(%s): %v", name, err)
		}
		ids = append(ids, uint16(f.sentQuery[0])<<8|uint16(f.sentQuery[1]))
	}
	seen := map[uint16]bool{}
	for _, id := range ids {
		if seen[id] {
			t.Fatalf("query ID %d reused — the CSPRNG draw must not repeat", id)
		}
		seen[id] = true
	}
	if f.listenCalls != 3 || f.closeCalls != 3 {
		t.Fatalf("transactions bound %d and closed %d ports, want 3 each", f.listenCalls, f.closeCalls)
	}
}

func TestResolve_LongNameRefusedBeforeSyscall(t *testing.T) {
	f := startDNSFake(t)
	name := ""
	for i := 0; i < 60; i++ {
		if i > 0 {
			name += "."
		}
		name += "abcdefgh"
	}
	if _, err := Resolve(name, DefaultDNSServer, DNSQueryA, 0); !errors.Is(err, ErrNameTooLong) {
		t.Fatalf("Resolve(long) = %v, want ErrNameTooLong", err)
	}
	if f.listenCalls != 0 || f.sendCalls != 0 || f.recvCalls != 0 {
		t.Fatalf("refused resolve touched the seam: listen=%d send=%d recv=%d",
			f.listenCalls, f.sendCalls, f.recvCalls)
	}
}

func TestResolve_SendRefusedIsNotRetried(t *testing.T) {
	// The seam refuses the send (EINVAL: .no_peer — the server's MAC is
	// not in ARP) and resolves nothing itself. Resolve-then-retry stays
	// the CALLER's contract: one send, no recv, an honest error — and the
	// bound port is still released.
	sendCalls := 0
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte { return nil }
	prev := SetSyscallHookForTest(f.hook)
	prev6 := SetSyscallHook6ForTest(func(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
		sendCalls++
		return -ErrEINVAL
	})
	defer SetSyscallHookForTest(prev)
	defer SetSyscallHook6ForTest(prev6)

	_, err := Resolve("myhost.local", DefaultDNSServer, DNSQueryA, 0)
	if !errors.Is(err, ErrDNSRefused) {
		t.Fatalf("Resolve with a refused send = %v, want ErrDNSRefused", err)
	}
	if sendCalls != 1 {
		t.Fatalf("send calls = %d, want exactly one — the retry is the caller's", sendCalls)
	}
	if f.closeCalls != 1 {
		t.Fatalf("the bound port leaked on the refusal path: closes=%d", f.closeCalls)
	}
}

func TestResolve_NXDOMAIN(t *testing.T) {
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte {
		r := dnsReplyFor(f.sentQuery, [4]byte{1, 2, 3, 4})
		r[3] = 0x83 // RCODE 3 in the low nibble of the second flags byte
		return dgram(f, r)
	}
	if _, err := Resolve("nosuch.name", DefaultDNSServer, DNSQueryA, 0); !errors.Is(err, ErrNameNotFound) {
		t.Fatalf("NXDOMAIN = %v, want ErrNameNotFound", err)
	}
}

func TestResolve_TimeoutFailsClosed(t *testing.T) {
	// A server that never answers must fail closed on the wall-clock
	// budget — after PARKING between polls (the M65 pacing), never
	// spinning — and must still release its port.
	f := startDNSFake(t)
	_, err := Resolve("myhost.local", DefaultDNSServer, DNSQueryA, 2_000_000) // 2 ms
	if !errors.Is(err, error(errno(ErrETIMEDOUT))) {
		t.Fatalf("unanswered resolve = %v, want Errno(ETIMEDOUT)", err)
	}
	if f.sleeps == 0 {
		t.Fatal("the wait must park between polls, not spin")
	}
	if f.recvCalls < 2 {
		t.Fatalf("recv polled %d times over the budget, want several", f.recvCalls)
	}
	if f.closeCalls != 1 {
		t.Fatalf("the bound port leaked on the timeout path: closes=%d", f.closeCalls)
	}
}

func TestResolve_SpoofedSourceIPIgnored(t *testing.T) {
	// A reply from a DIFFERENT source IP is the spoof the slot-85 prefix
	// exists to catch: consumed, counted, and the poll continues to the
	// genuine answer.
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte {
		if call == 1 {
			return udpDgramFrom([4]byte{192, 0, 2, 99}, DNSPort, uint16(f.sentSrcPort),
				dnsReplyFor(f.sentQuery, [4]byte{6, 6, 6, 6}))
		}
		return dgram(f, dnsReplyFor(f.sentQuery, [4]byte{10, 0, 0, 2}))
	}
	res, err := Resolve("myhost.local", dnsTestServer, DNSQueryA, 0)
	if err != nil || res.Addrs[0].IPv4 != [4]byte{10, 0, 0, 2} {
		t.Fatalf("resolve after a spoof = (%v, %v), want 10.0.0.2", res, err)
	}
	if res.Ignored != 1 {
		t.Fatalf("ignored = %d, want 1 — the spoof counts in the report", res.Ignored)
	}
}

func TestResolve_WrongPortAndQuestionIgnored(t *testing.T) {
	// Two failure classes in the same receipt: a datagram from a
	// non-resolver port, and one whose question section does not echo
	// ours byte-for-byte even with the right ID/IP/port.
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte {
		switch call {
		case 1:
			return udpDgramFrom(dnsTestServer, 9999, uint16(f.sentSrcPort), []byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11})
		case 2:
			r := dnsReplyFor(f.sentQuery, [4]byte{1, 1, 1, 1})
			r[12+1] ^= 0xFF // mangle one byte of the echoed QNAME
			return dgram(f, r)
		}
		return dgram(f, dnsReplyFor(f.sentQuery, [4]byte{10, 0, 0, 2}))
	}
	res, err := Resolve("myhost.local", dnsTestServer, DNSQueryA, 0)
	if err != nil || res.Addrs[0].IPv4 != [4]byte{10, 0, 0, 2} {
		t.Fatalf("resolve = (%v, %v), want 10.0.0.2", res, err)
	}
	if res.Ignored != 2 {
		t.Fatalf("ignored = %d, want 2 (wrong port + wrong question)", res.Ignored)
	}
}

func TestResolve_AAAA(t *testing.T) {
	f := startDNSFake(t)
	want := [16]byte{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x2a}
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyAAAA(f.sentQuery, want))
	}
	res, err := Resolve("v6.example", dnsTestServer, DNSQueryAAAA, 0)
	if err != nil {
		t.Fatalf("Resolve AAAA: %v", err)
	}
	if len(res.Addrs) != 1 || !res.Addrs[0].V6 || res.Addrs[0].IPv6 != want {
		t.Fatalf("resolved %+v, want %v", res.Addrs, want)
	}
	// The query asked for type 28 in the question section.
	qt := uint16(f.sentQuery[len(f.sentQuery)-4])<<8 | uint16(f.sentQuery[len(f.sentQuery)-3])
	if qt != DNSQueryAAAA {
		t.Fatalf("QTYPE = %d, want AAAA (28)", qt)
	}
}

func TestResolve_MultiAnswerFirstUsable(t *testing.T) {
	// ANCOUNT=3: A, a CNAME the walker skips, A. The result reports the
	// walked count and the first usable A — and collects both As.
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyMulti(f.sentQuery, [4]byte{10, 0, 0, 9}, [4]byte{10, 0, 0, 10}))
	}
	res, err := Resolve("multi.example", dnsTestServer, DNSQueryA, 0)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if res.Answers != 3 {
		t.Fatalf("answers = %d, want 3 (every record walked)", res.Answers)
	}
	if len(res.Addrs) != 2 || res.Addrs[0].IPv4 != [4]byte{10, 0, 0, 9} || res.Addrs[1].IPv4 != [4]byte{10, 0, 0, 10} {
		t.Fatalf("addrs = %+v, want [10.0.0.9 10.0.0.10]", res.Addrs)
	}
}

func TestResolve_TruncatedRefused(t *testing.T) {
	// TC=1 is ErrDNSTruncated — explicit, never ErrDNSFailed, and never
	// a TCP retry this seam does not have.
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte {
		r := dnsReplyFor(f.sentQuery, [4]byte{10, 0, 0, 2})
		r[2] |= 0x02
		return dgram(f, r)
	}
	if _, err := Resolve("big.example", dnsTestServer, DNSQueryA, 0); !errors.Is(err, ErrDNSTruncated) {
		t.Fatalf("TC=1 = %v, want ErrDNSTruncated", err)
	}
}

func TestResolve_TTLClampBounds(t *testing.T) {
	// TTL below the floor clamps to 5s; above the ceiling to 1h.
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyTTL(f.sentQuery, [4]byte{10, 0, 0, 2}, 0))
	}
	res, err := Resolve("floor.example", dnsTestServer, DNSQueryA, 0)
	if err != nil || res.TTLNs != dnsTTLFloorNs {
		t.Fatalf("TTL 0 = %v (%v), want the 5s floor", res.TTLNs, err)
	}
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyTTL(f.sentQuery, [4]byte{10, 0, 0, 2}, 86_400))
	}
	res, err = Resolve("ceil.example", dnsTestServer, DNSQueryA, 0)
	if err != nil || res.TTLNs != dnsTTLCapNs {
		t.Fatalf("TTL 86400 = %v (%v), want the 1h cap", res.TTLNs, err)
	}
}

func TestResolve_CacheHitSendsNothing(t *testing.T) {
	// The second identical lookup is served from the table: no bind, no
	// send, no recv — the cache-hit proof is zero NEW seam traffic.
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyFor(f.sentQuery, [4]byte{10, 0, 0, 2}))
	}
	r1, err := Resolve("cached.example", dnsTestServer, DNSQueryA, 0)
	if err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	sends, listens, recvs := f.sendCalls, f.listenCalls, f.recvCalls
	r2, err := Resolve("cached.example", dnsTestServer, DNSQueryA, 0)
	if err != nil {
		t.Fatalf("second resolve: %v", err)
	}
	if !r2.Cached || r2.Addrs[0].IPv4 != r1.Addrs[0].IPv4 {
		t.Fatalf("second resolve = %+v, want a cached copy of the first", r2)
	}
	if f.sendCalls != sends || f.listenCalls != listens || f.recvCalls != recvs {
		t.Fatalf("cache hit touched the wire: +%d sends +%d binds +%d recvs",
			f.sendCalls-sends, f.listenCalls-listens, f.recvCalls-recvs)
	}
	if r2.TTLNs <= 0 || r2.TTLNs > r1.TTLNs {
		t.Fatalf("cached TTL %d should be the first's remaining lifetime (<%d)", r2.TTLNs, r1.TTLNs)
	}
	// A different server or family is a different cache key — it MUST
	// hit the wire.
	if _, err := Resolve("cached.example", [4]byte{10, 0, 0, 3}, DNSQueryA, 0); err != nil {
		t.Fatalf("other-server resolve: %v", err)
	}
	if f.sendCalls == sends {
		t.Fatal("a different server wrongly answered from cache")
	}
}

func TestResolve_CacheExpiryRefreshes(t *testing.T) {
	// An entry past its expiry is dead: the lookup goes back to the
	// wire. The unit test cannot wait out the 5s floor, so it backdates
	// the entry — the same thing the live gate proves with a 1s TTL.
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyFor(f.sentQuery, [4]byte{10, 0, 0, 2}))
	}
	if _, err := Resolve("expiry.example", dnsTestServer, DNSQueryA, 0); err != nil {
		t.Fatalf("first resolve: %v", err)
	}
	dnsCacheMu.Lock()
	for i := range dnsCache {
		if dnsCache[i].valid {
			dnsCache[i].expiry = 0 // in the past
		}
	}
	dnsCacheMu.Unlock()
	sends := f.sendCalls
	r, err := Resolve("expiry.example", dnsTestServer, DNSQueryA, 0)
	if err != nil || r.Cached {
		t.Fatalf("expired resolve = (%+v, %v), want a fresh wire answer", r, err)
	}
	if f.sendCalls != sends+1 {
		t.Fatalf("expired entry did not re-query: sends %d -> %d", sends, f.sendCalls)
	}
}

func TestResolve_BindCollisionRetries(t *testing.T) {
	// A claimed ephemeral port (EINVAL) draws a fresh one; the bind
	// retry stays inside the transaction.
	f := startDNSFake(t)
	f.refuseBinds = 2
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyFor(f.sentQuery, [4]byte{10, 0, 0, 2}))
	}
	if _, err := Resolve("collide.example", dnsTestServer, DNSQueryA, 0); err != nil {
		t.Fatalf("resolve after collisions: %v", err)
	}
	if f.listenCalls != 3 {
		t.Fatalf("binds = %d, want 3 (two refused, one taken)", f.listenCalls)
	}
}

func TestResolve_BindTableFullFails(t *testing.T) {
	// ENOSPC is not retried: the table is full, a fresh port cannot
	// help.
	f := startDNSFake(t)
	f.refuseENOSPC = true
	if _, err := Resolve("full.example", dnsTestServer, DNSQueryA, 0); err == nil {
		t.Fatal("a full listen table must fail the resolve")
	}
	if f.listenCalls != 1 {
		t.Fatalf("binds = %d, want 1 — ENOSPC does not retry", f.listenCalls)
	}
}

func TestResolveDNS_LegacyWrapper(t *testing.T) {
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyFor(f.sentQuery, [4]byte{93, 184, 216, 34}))
	}
	ip, err := ResolveDNS("myhost.local", dnsTestServer, 0)
	if err != nil || ip != [4]byte{93, 184, 216, 34} {
		t.Fatalf("ResolveDNS = (%v, %v), want 93.184.216.34", ip, err)
	}
}

func TestResolveDNS6_LegacyWrapper(t *testing.T) {
	// M184a (#3174): the AAAA twin of ResolveDNS — the same first-record
	// pick on the v6 answers.
	f := startDNSFake(t)
	want := [16]byte{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x53}
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyAAAA(f.sentQuery, want))
	}
	ip, err := ResolveDNS6("v6.example", dnsTestServer, 0)
	if err != nil || ip != want {
		t.Fatalf("ResolveDNS6 = (%v, %v), want %v", ip, err, want)
	}
}

func TestResolve_NoRecordNamesTheFamily(t *testing.T) {
	// A NOERROR answer carrying nothing of the asked family names the
	// family (M184a): ErrNoARecord / ErrNoAAAARecord, not the generic
	// failure — the NODATA the fallback ordering keys on and the name
	// an app's error line can print.
	f := startDNSFake(t)
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsNODATA(f.sentQuery))
	}
	if _, err := Resolve("empty.example", dnsTestServer, DNSQueryA, 0); !errors.Is(err, ErrNoARecord) {
		t.Fatalf("A NODATA = %v, want ErrNoARecord", err)
	}
	if _, err := Resolve("empty.example", dnsTestServer, DNSQueryAAAA, 0); !errors.Is(err, ErrNoAAAARecord) {
		t.Fatalf("AAAA NODATA = %v, want ErrNoAAAARecord", err)
	}
	// An answer of the WRONG family is NODATA for the one asked: an A
	// reply to an AAAA question (and back) still names the family.
	f.recvScript = func(port uint16, call int) []byte {
		return dgram(f, dnsReplyFor(f.sentQuery, [4]byte{10, 0, 0, 2}))
	}
	if _, err := Resolve("onlya.example", dnsTestServer, DNSQueryAAAA, 0); !errors.Is(err, ErrNoAAAARecord) {
		t.Fatalf("AAAA asked, A answered = %v, want ErrNoAAAARecord", err)
	}
}

func TestParseDNSReply_MalformedAndUnanswered(t *testing.T) {
	startDNSFake(t) // the query ID draws on getrandom
	query, id, err := buildDNSQuery("myhost.local", DNSQueryA)
	if err != nil {
		t.Fatalf("buildDNSQuery: %v", err)
	}
	question := query[12:]
	full := dnsReplyFor(query, [4]byte{10, 0, 0, 2})
	parse := func(msg []byte) (DNSResult, error) {
		return parseDNSReply(udpDgramFrom(dnsTestServer, DNSPort, 53, msg), dnsTestServer, id, question, DNSQueryA)
	}

	// An answer cut short is refused, not parsed as a zero address.
	truncated := append([]byte(nil), full[:len(full)-2]...)
	if _, err := parse(truncated); !errors.Is(err, ErrDNSFailed) {
		t.Fatalf("truncated reply = %v, want ErrDNSFailed", err)
	}
	// A response with no A record is the family's named NODATA — not
	// the generic failure, so the caller can ask the other family.
	noAnswer := append([]byte(nil), full[:len(query)]...)
	noAnswer[6], noAnswer[7] = 0x00, 0x00 // ANCOUNT = 0
	if _, err := parse(noAnswer); !errors.Is(err, ErrNoARecord) {
		t.Fatalf("empty answer = %v, want ErrNoARecord", err)
	}
	// A query (QR = 0) is not our reply.
	if _, err := parse(query); !errors.Is(err, errNotOurs) {
		t.Fatalf("a query echoed back = %v, want errNotOurs", err)
	}
	// A different ID is not our reply.
	if _, err := parseDNSReply(udpDgramFrom(dnsTestServer, DNSPort, 53, full), dnsTestServer, id+1, question, DNSQueryA); !errors.Is(err, errNotOurs) {
		t.Fatalf("mismatched ID = %v, want errNotOurs", err)
	}
	// A reply from a different server is a spoof — not ours.
	if _, err := parseDNSReply(udpDgramFrom([4]byte{8, 8, 8, 8}, DNSPort, 53, full), dnsTestServer, id, question, DNSQueryA); !errors.Is(err, errNotOurs) {
		t.Fatalf("wrong source IP = %v, want errNotOurs", err)
	}
}

func TestParseDNSReply_HostileVectors(t *testing.T) {
	startDNSFake(t) // the query ID draws on getrandom
	query, id, err := buildDNSQuery("myhost.local", DNSQueryA)
	if err != nil {
		t.Fatalf("buildDNSQuery: %v", err)
	}
	question := query[12:]
	full := dnsReplyFor(query, [4]byte{10, 0, 0, 2})
	parse := func(msg []byte) (DNSResult, error) {
		return parseDNSReply(udpDgramFrom(dnsTestServer, DNSPort, 53, msg), dnsTestServer, id, question, DNSQueryA)
	}

	// SERVFAIL (2) and REFUSED (5) are honest failures, never a zero IP.
	for _, rcode := range []byte{2, 5} {
		r := append([]byte(nil), full...)
		r[3] = 0x80 | rcode
		if _, err := parse(r); !errors.Is(err, ErrDNSFailed) {
			t.Fatalf("rcode %d = %v, want ErrDNSFailed", rcode, err)
		}
	}
	// TC = 1: the reply was cut off in transit — the named refusal.
	tc := append([]byte(nil), full...)
	tc[2] |= 0x02
	if _, err := parse(tc); !errors.Is(err, ErrDNSTruncated) {
		t.Fatalf("TC=1 = %v, want ErrDNSTruncated", err)
	}
	// A host claiming 65535 answers runs off the copied datagram: the
	// bounds check fires before any record is trusted.
	many := append([]byte(nil), full[:12]...)
	many = append(many, query[12:]...)
	many[6], many[7] = 0xff, 0xff // ANCOUNT = 65535
	many = append(many, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0, 0, 1, 0x2C, 0, 4, 1, 2, 3, 4)
	if _, err := parse(many); !errors.Is(err, ErrDNSFailed) {
		t.Fatalf("ANCOUNT=65535 = %v, want ErrDNSFailed", err)
	}
	// A compression pointer that points at ITSELF: the walker skips two
	// bytes without following it, so the parse terminates.
	selfPtr := append([]byte(nil), full[:12]...)
	selfPtr = append(selfPtr, query[12:]...)
	selfPtr[6], selfPtr[7] = 0x00, 0x01   // ANCOUNT = 1
	selfPtr = append(selfPtr, 0xC0, 0x0C, // a name pointer at offset 12: itself
		0x00, 0x01, 0x00, 0x01, 0, 0, 1, 0x2C, 0, 4, 1, 2, 3, 4)
	res, err := parse(selfPtr)
	if err != nil || len(res.Addrs) != 1 || res.Addrs[0].IPv4 != [4]byte{1, 2, 3, 4} {
		t.Fatalf("self-pointer name = (%v, %v), want 1.2.3.4 with no error", res, err)
	}
	// A datagram too short to hold a DNS header is a stray, not a failure.
	if _, err := parse([]byte{0, 1, 2, 3, 4, 5}); !errors.Is(err, errNotOurs) {
		t.Fatalf("short datagram = %v, want errNotOurs", err)
	}
}
