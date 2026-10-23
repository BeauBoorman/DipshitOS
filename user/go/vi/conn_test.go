package vi

import (
	"errors"
	"sync"
	"testing"
	"time"
)

// The socket fake: scripts the slot-80 socket ABI (op 10 connect, op 0
// listen, ops 1-7 per-handle I/O, op 12 table) AND the legacy slot
// 30-33/76 shim the unchanged vi.Listen path still uses. The slot-80
// side is a tiny table keyed by handle — minting, ready, read, send,
// accept and close are all scripted so the Conn type's routing can be
// observed without a kernel.
type connFake struct {
	// legacy slot-30 surface (vi.Listen's path).
	connectCalls int
	connectIP    uint32
	connectPort  uintptr
	connectRC    int64
	sendCalls    int
	sentSizes    []int
	sentBytes    []byte
	recvCalls    int
	closeCalls   int
	probeCalls   int
	sleeps       int
	other        int
	probeMask    int64
	probeScript  func(call int) int64
	recvScript   func(call int) ([]byte, int64)
	sendRC       int64

	// slot-80 table.
	mu          sync.Mutex // serializes op calls for concurrent dials
	opLog       []int      // every op seen, in order
	sockGen     uint64     // handle allocator (gen<<4|slot)
	socks       map[uint64]*fSock
	connectErr  int64 // fixed op-10 refusal when set
	listenErr   int64 // op-0 refusal
	readyScript func(h uint64, call int) int64
	readyCalls  int
	readScript  func(h uint64, call int) ([]byte, int64)
	sockSendRC  int64
	sockSendErr map[uint64]int64 // per-handle send refusal
	op10Calls   int
	op10A1      uintptr  // the last connect's args[1] (ipv4Word or familyV6Tag)
	op10Addr    [16]byte // the last connect's copy-in target when tagged v6
	op12Rows    []SocketRow
}

// fSock is one scripted table socket.
type fSock struct {
	kind     int // 0 listener, 1 conn
	closed   bool
	readable bool
	writable bool
	accepted bool
	pending  []uint64 // listener: established children awaiting accept
	shutdown bool
}

func (f *connFake) mint(kind int) uint64 {
	f.sockGen++
	h := f.sockGen<<4 | 4 // conn-slot base; listeners get slot 0..3 below
	if f.socks == nil {
		f.socks = map[uint64]*fSock{}
	}
	f.socks[h] = &fSock{kind: kind}
	return h
}

func (f *connFake) mintListener() uint64 {
	f.sockGen++
	h := f.sockGen << 4 // slot 0
	if f.socks == nil {
		f.socks = map[uint64]*fSock{}
	}
	f.socks[h] = &fSock{kind: 0}
	return h
}

func (f *connFake) sock(op int, a1, a2, a3 uintptr) int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.opLog = append(f.opLog, op)
	h64 := uint64(a1)
	switch op {
	case SockOpListen:
		if f.listenErr != 0 {
			return f.listenErr
		}
		return int64(f.mintListener())
	case SockOpConnect:
		f.op10Calls++
		f.op10A1 = a1
		if a1 == familyV6Tag {
			copy(f.op10Addr[:], hookBytes(a3, 16))
		}
		if f.connectErr != 0 {
			return f.connectErr
		}
		return int64(f.mint(1))
	case SockOpAccept:
		s := f.socks[h64]
		if s == nil || len(s.pending) == 0 {
			return -ErrEAGAIN
		}
		h := s.pending[0]
		s.pending = s.pending[1:]
		f.socks[h].accepted = true
		return int64(h)
	case SockOpReady:
		f.readyCalls++
		if f.readyScript != nil {
			return f.readyScript(h64, f.readyCalls)
		}
		s := f.socks[h64]
		if s == nil || s.closed {
			return -ErrEBADF
		}
		var mask int64
		if s.kind == 0 {
			if len(s.pending) > 0 {
				mask |= readyAccept
			}
			return mask
		}
		if s.readable {
			mask |= readyRead
		}
		if s.writable {
			mask |= readyWrite
		}
		return mask
	case SockOpRead:
		s := f.socks[h64]
		if s == nil || s.closed {
			return -errSockClosed
		}
		f.recvCalls++
		if f.readScript != nil {
			b, rc := f.readScript(h64, f.recvCalls)
			if b != nil {
				copy(hookBytes(a2, uintptr(len(b))), b)
			}
			return rc
		}
		return 0
	case SockOpSend:
		s := f.socks[h64]
		if s == nil || s.closed {
			return -errSockClosed
		}
		f.sendCalls++
		b := hookBytes(a2, a3)
		f.sentSizes = append(f.sentSizes, len(b))
		f.sentBytes = append(f.sentBytes, b...)
		if f.sockSendErr != nil {
			if rc, ok := f.sockSendErr[h64]; ok {
				return rc
			}
		}
		if f.sockSendRC != 0 {
			return f.sockSendRC
		}
		return int64(a3)
	case SockOpClose:
		if s := f.socks[h64]; s != nil {
			s.closed = true
		}
		f.closeCalls++
		return 0
	case SockOpShutdown:
		if s := f.socks[h64]; s != nil {
			s.shutdown = true
		}
		return 0
	case SockOpPeer:
		return int64(0x0a000002<<16 | 8080)
	case SockOpTable:
		for i, row := range f.op12Rows {
			var b [24]byte
			for j := 0; j < 8; j++ {
				b[j] = byte(row.Owner >> (8 * j))
			}
			copy(b[8:12], row.LocalIP[:])
			b[12] = byte(row.LocalPort)
			b[13] = byte(row.LocalPort >> 8)
			b[14] = byte(row.RemotePort)
			b[15] = byte(row.RemotePort >> 8)
			copy(b[16:20], row.RemoteIP[:])
			b[20] = row.Kind
			b[21] = row.State
			copy(hookBytes(a1+uintptr(i)*24, 24), b[:])
		}
		return int64(len(f.op12Rows))
	}
	f.other++
	return -ErrENOSYS
}

func (f *connFake) hook(num uintptr, a0, a1, a2, a3 uintptr) int64 {
	switch num {
	case SlotSocket:
		return f.sock(int(a0), a1, a2, a3)
	case SlotTCPConnect:
		f.connectCalls++
		f.connectIP = uint32(a0)
		f.connectPort = a1
		return f.connectRC
	case SlotTCPSend:
		f.sendCalls++
		b := hookBytes(a0, a1)
		f.sentSizes = append(f.sentSizes, len(b))
		f.sentBytes = append(f.sentBytes, b...)
		if f.sendRC != 0 {
			return f.sendRC
		}
		return int64(a1)
	case SlotTCPRecv:
		f.recvCalls++
		if f.recvScript == nil {
			return 0
		}
		b, rc := f.recvScript(f.recvCalls)
		if b != nil {
			copy(hookBytes(a0, uintptr(len(b))), b)
		}
		return rc
	case SlotTCPClose:
		f.closeCalls++
		return 0
	case SlotSockReady:
		f.probeCalls++
		if f.probeScript != nil {
			return f.probeScript(f.probeCalls)
		}
		return f.probeMask
	case SlotSleep:
		f.sleeps++
		return 0
	}
	f.other++
	return -ErrENOSYS
}

func startConnFake(t *testing.T) *connFake {
	t.Helper()
	f := &connFake{}
	prev := SetSyscallHookForTest(f.hook)
	t.Cleanup(func() { SetSyscallHookForTest(prev) })
	return f
}

func (f *connFake) opsCalled(op int) int {
	n := 0
	for _, o := range f.opLog {
		if o == op {
			n++
		}
	}
	return n
}

func TestDial_LiteralConnects(t *testing.T) {
	f := startConnFake(t)
	c, err := Dial("10.0.0.2", 8080)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	if f.op10Calls != 1 || f.connectCalls != 0 {
		t.Fatalf("connect = %d op-10 / %d slot-30 calls, want 1 / 0", f.op10Calls, f.connectCalls)
	}
	if c.Handle() == 0 {
		t.Fatal("Dial did not mint a table handle")
	}
	if c.IP() != [4]byte{10, 0, 0, 2} || c.Port() != 8080 {
		t.Fatalf("peer = %v:%d, want 10.0.0.2:8080", c.IP(), c.Port())
	}
}

func TestDialTimeout_EncodesMilliseconds(t *testing.T) {
	for _, d := range []time.Duration{time.Nanosecond, time.Millisecond, 5 * time.Second, 5*time.Second + time.Nanosecond, 0xffffffff * time.Millisecond} {
		t.Run(d.String(), func(t *testing.T) {
			f := startConnFake(t)
			c, err := DialTimeout("10.0.0.2", 8080, d)
			if err != nil {
				t.Fatal(err)
			}
			if f.op10Calls != 1 {
				t.Fatalf("connect = %d op-10 calls, want 1", f.op10Calls)
			}
			if c.Port() != 8080 || c.IP() != [4]byte{10, 0, 0, 2} {
				t.Fatalf("peer = %v:%d", c.IP(), c.Port())
			}
		})
	}
}

func TestDialTimeout_InvalidDurationDoesNotConnect(t *testing.T) {
	for _, d := range []time.Duration{-1, 0, 0xffffffff*time.Millisecond + 1, time.Duration(1<<63 - 1)} {
		f := startConnFake(t)
		if c, err := DialTimeout("10.0.0.2", 8080, d); c != nil || !errors.Is(err, errno(ErrEINVAL)) {
			t.Fatalf("DialTimeout(%v) = %v, %v", d, c, err)
		}
		if f.op10Calls != 0 {
			t.Fatal("invalid duration reached op 10")
		}
	}
}

func TestDial_TimeoutRefusalIsClean(t *testing.T) {
	// The kernel releases the half-open conn itself on a connect
	// refusal: the caller only sees the errno and owes no close.
	f := startConnFake(t)
	f.connectErr = -ErrETIMEDOUT
	if c, err := DialTimeout("10.0.0.2", 8081, 5*time.Second); c != nil || !errors.Is(err, errno(ErrETIMEDOUT)) {
		t.Fatalf("timeout = %v, %v", c, err)
	}
	if f.opsCalled(SockOpClose) != 0 {
		t.Fatal("a refused connect owed a close — the kernel already released it")
	}
	f.connectErr = 0
	if _, err := Dial("10.0.0.2", 8080); err != nil {
		t.Fatal(err)
	}
	if f.op10Calls != 2 {
		t.Fatal("the next Dial did not mint its own conn")
	}
}

func TestDial_ZeroGuards(t *testing.T) {
	f := startConnFake(t)
	if _, err := DialTimeout("10.0.0.2", 0, time.Second); !errors.Is(err, errno(ErrEINVAL)) {
		t.Fatal(err)
	}
	if _, err := DialTimeout("0.0.0.0", 8080, time.Second); !errors.Is(err, ErrServerDial) {
		t.Fatal(err)
	}
	if _, err := Dial("10.0.0.2", 0); !errors.Is(err, errno(ErrEINVAL)) {
		t.Fatal(err)
	}
	if _, err := Dial("0.0.0.0", 8080); !errors.Is(err, ErrServerDial) {
		t.Fatal(err)
	}
	if f.op10Calls != 0 {
		t.Fatal("invalid peer reached op 10")
	}
}

// dialNameFakes wires a dnsFake and a connFake under one hook pair —
// the name path's two seams (the DNS transaction on the UDP slots, the
// connect marshal on slot 80).
func dialNameFakes(t *testing.T) (*dnsFake, *connFake) {
	t.Helper()
	dns := &dnsFake{bound: map[uint16]bool{}, recvPer: map[uint16]int{}}
	f := &connFake{}
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotSocket {
			return f.hook(num, a0, a1, a2, a3)
		}
		return dns.hook(num, a0, a1, a2, a3)
	})
	prev6 := SetSyscallHook6ForTest(dns.hook6)
	t.Cleanup(func() { SetSyscallHookForTest(prev) })
	t.Cleanup(func() { SetSyscallHook6ForTest(prev6) })
	t.Cleanup(resetDNSCacheForTest)
	return dns, f
}

func TestDial_NameResolvesThenConnects(t *testing.T) {
	// A name dials the RESOLVED address: the DNS seam runs first (the fake
	// answers myhost.local -> 10.0.0.2), then op 10 carries the octets.
	dns, f := dialNameFakes(t)
	dns.recvScript = func(port uint16, call int) []byte {
		return dgram(dns, dnsReplyFor(dns.sentQuery, [4]byte{10, 0, 0, 2}))
	}
	c, err := Dial("myhost.local", 8080)
	if err != nil {
		t.Fatalf("Dial by name: %v", err)
	}
	if f.op10Calls != 1 || c.IP() != [4]byte{10, 0, 0, 2} {
		t.Fatalf("resolved dial = %d calls, peer %v", f.op10Calls, c.IP())
	}
	// v4-first ordering: one A question, no AAAA question — an
	// A-answering name behaves exactly as before.
	if len(dns.sentQTypes) != 1 || dns.sentQTypes[0] != DNSQueryA {
		t.Fatalf("queries = %v, want exactly one A", dns.sentQTypes)
	}
}

func TestDial_DNSResolvingToZeroRefused(t *testing.T) {
	// The passive-open answer is undialable, so the name earns its AAAA
	// question first (M184a); the fake answers that with an A record —
	// nothing dialable in either family — and the refusal stays named.
	dns, f := dialNameFakes(t)
	dns.recvScript = func(port uint16, call int) []byte {
		return dgram(dns, dnsReplyFor(dns.sentQuery, [4]byte{0, 0, 0, 0}))
	}
	if _, err := Dial("zero.host", 8080); !errors.Is(err, ErrServerDial) {
		t.Fatalf("Dial of a name resolving to 0.0.0.0 = %v, want ErrServerDial", err)
	}
	if f.op10Calls != 0 {
		t.Fatal("the resolved zero address reached op 10")
	}
	if len(dns.sentQTypes) != 2 || dns.sentQTypes[0] != DNSQueryA || dns.sentQTypes[1] != DNSQueryAAAA {
		t.Fatalf("queries = %v, want A then AAAA", dns.sentQTypes)
	}
}

func TestDial_NameAAAAOnlyDialsV6(t *testing.T) {
	// The card's bet: a name whose only record is AAAA. A comes back
	// NODATA, AAAA carries the peer, and op 10 gets the tagged marshal
	// the literal v6 path uses.
	dns, f := dialNameFakes(t)
	want := [16]byte{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0x00, 0x02}
	dns.recvScript = func(port uint16, call int) []byte {
		if queryQType(dns.sentQuery) == DNSQueryAAAA {
			return dgram(dns, dnsReplyAAAA(dns.sentQuery, want))
		}
		return dgram(dns, dnsNODATA(dns.sentQuery))
	}
	c, err := Dial("v6only.example", 8080)
	if err != nil {
		t.Fatalf("Dial AAAA-only name: %v", err)
	}
	if !c.IsV6() || c.IP6() != want || c.Port() != 8080 {
		t.Fatalf("conn = v6:%v ip6:%v port:%d, want v6 %v:8080", c.IsV6(), c.IP6(), c.Port(), want)
	}
	if f.op10Calls != 1 || f.op10A1 != familyV6Tag || f.op10Addr != want {
		t.Fatalf("op10 = %d calls a1=%#x addr=%v, want the tagged v6 marshal",
			f.op10Calls, f.op10A1, f.op10Addr)
	}
	if len(dns.sentQTypes) != 2 || dns.sentQTypes[0] != DNSQueryA || dns.sentQTypes[1] != DNSQueryAAAA {
		t.Fatalf("queries = %v, want A then AAAA", dns.sentQTypes)
	}
}

func TestDial_NameZeroAFallsToAAAA(t *testing.T) {
	// An A answer of nothing but the passive-open zero is NODATA's
	// practical twin: the name gets its AAAA question before the
	// refusal — and here the AAAA answer dials.
	dns, f := dialNameFakes(t)
	want := [16]byte{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x53}
	dns.recvScript = func(port uint16, call int) []byte {
		if queryQType(dns.sentQuery) == DNSQueryAAAA {
			return dgram(dns, dnsReplyAAAA(dns.sentQuery, want))
		}
		return dgram(dns, dnsReplyFor(dns.sentQuery, [4]byte{0, 0, 0, 0}))
	}
	c, err := Dial("zeroa.example", 8080)
	if err != nil || !c.IsV6() || c.IP6() != want {
		t.Fatalf("Dial zero-A name = (%v, %v), want v6 %v", c, err, want)
	}
	if f.op10Calls != 1 || f.op10A1 != familyV6Tag {
		t.Fatalf("op10 = %d calls a1=%#x, want the tagged marshal", f.op10Calls, f.op10A1)
	}
}

func TestDial_NameNXDOMAINKeepsItsRefusal(t *testing.T) {
	// NXDOMAIN is name-level — the AAAA question would meet the same
	// answer, so it is never asked: one query, ErrNameNotFound.
	dns, _ := dialNameFakes(t)
	dns.recvScript = func(port uint16, call int) []byte {
		r := dnsReplyFor(dns.sentQuery, [4]byte{1, 2, 3, 4})
		r[3] = 0x83
		return dgram(dns, r)
	}
	if _, err := Dial("nosuch.name", 8080); !errors.Is(err, ErrNameNotFound) {
		t.Fatalf("NXDOMAIN dial = %v, want ErrNameNotFound", err)
	}
	if len(dns.sentQTypes) != 1 || dns.sentQTypes[0] != DNSQueryA {
		t.Fatalf("queries = %v, want exactly one A", dns.sentQTypes)
	}
}

func TestDial_NameBothFamiliesEmptyRefused(t *testing.T) {
	// NODATA in both directions: the refusal names the pair, never a
	// bare resolution failure.
	dns, f := dialNameFakes(t)
	dns.recvScript = func(port uint16, call int) []byte {
		return dgram(dns, dnsNODATA(dns.sentQuery))
	}
	if _, err := Dial("empty.example", 8080); !errors.Is(err, ErrNameNoAddr) {
		t.Fatalf("empty name dial = %v, want ErrNameNoAddr", err)
	}
	if len(dns.sentQTypes) != 2 || dns.sentQTypes[0] != DNSQueryA || dns.sentQTypes[1] != DNSQueryAAAA {
		t.Fatalf("queries = %v, want A then AAAA", dns.sentQTypes)
	}
	if f.op10Calls != 0 {
		t.Fatal("an empty name reached op 10")
	}
}

func TestDial_NameUndialableAnswersRefused(t *testing.T) {
	// Every record the name gave is undialable — A=0.0.0.0, then
	// AAAA=:: — the refusal names the passive-open answer and no
	// socket op is spent on it.
	dns, f := dialNameFakes(t)
	dns.recvScript = func(port uint16, call int) []byte {
		if queryQType(dns.sentQuery) == DNSQueryAAAA {
			return dgram(dns, dnsReplyAAAA(dns.sentQuery, [16]byte{}))
		}
		return dgram(dns, dnsReplyFor(dns.sentQuery, [4]byte{0, 0, 0, 0}))
	}
	if _, err := Dial("zeros.example", 8080); !errors.Is(err, ErrServerDial) {
		t.Fatalf("all-zeros dial = %v, want ErrServerDial", err)
	}
	if f.op10Calls != 0 {
		t.Fatal("an undialable answer reached op 10")
	}
}

func TestDial_NameAAAAOnlyBadDstRefused(t *testing.T) {
	// The v6 half of the same guard: a multicast AAAA answer is a bad
	// destination the kernel would refuse EINVAL — the resolver names
	// it first, without spending a socket op.
	dns, f := dialNameFakes(t)
	bad := [16]byte{0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
	dns.recvScript = func(port uint16, call int) []byte {
		if queryQType(dns.sentQuery) == DNSQueryAAAA {
			return dgram(dns, dnsReplyAAAA(dns.sentQuery, bad))
		}
		return dgram(dns, dnsNODATA(dns.sentQuery))
	}
	if _, err := Dial("multicast.example", 8080); !errors.Is(err, ErrServerDial) {
		t.Fatalf("bad-dst dial = %v, want ErrServerDial", err)
	}
	if f.op10Calls != 0 {
		t.Fatal("a bad-dst answer reached op 10")
	}
}

func TestDial_ConcurrentDialsEachHoldAConn(t *testing.T) {
	// M99g's headline: two racing Dials from one process each come back
	// with their own live handle — no userland bound in the way.
	f := startConnFake(t)
	const n = 2
	type result struct {
		c   *Conn
		err error
	}
	res := make(chan result, n)
	for i := 0; i < n; i++ {
		go func() {
			c, err := Dial("10.0.0.2", 8080)
			res <- result{c, err}
		}()
	}
	handles := map[uint64]bool{}
	for i := 0; i < n; i++ {
		r := <-res
		if r.err != nil {
			t.Fatalf("concurrent Dial %d = %v", i, r.err)
		}
		if handles[r.c.Handle()] {
			t.Fatal("two Dials share one handle")
		}
		handles[r.c.Handle()] = true
	}
	if f.op10Calls != n {
		t.Fatalf("connects = %d, want %d", f.op10Calls, n)
	}
}

func TestDial_TableFullIsConnBusyByName(t *testing.T) {
	// The bound is the kernel's: a Capacity (-5) refusal surfaces as
	// ErrConnBusy BY NAME — the fifth open at owner_limit=4, without
	// userland counting.
	f := startConnFake(t)
	var conns []*Conn
	for i := 0; i < 4; i++ {
		c, err := Dial("10.0.0.2", 8080)
		if err != nil {
			t.Fatalf("Dial %d = %v", i, err)
		}
		conns = append(conns, c)
	}
	f.connectErr = -ErrENOSPC // the kernel's fifth-Dial answer
	if c, err := Dial("10.0.0.2", 8080); c != nil || !errors.Is(err, ErrConnBusy) {
		t.Fatalf("fifth Dial = %v, %v want nil, ErrConnBusy", c, err)
	}
	if f.op10Calls != 5 {
		t.Fatalf("op-10 calls = %d, want 5 (the refusal came from the kernel)", f.op10Calls)
	}
	for _, c := range conns {
		if err := c.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	}
	// Capacity freed: the kernel answers again.
	f.connectErr = 0
	if _, err := Dial("10.0.0.2", 8080); err != nil {
		t.Fatalf("Dial after releases = %v", err)
	}
}

func TestListen_StillTheLegacyPath(t *testing.T) {
	// vi.Listen deliberately stays on slot 30: agentd/rfbserver drive the
	// accepted session over raw slots 31-33/76.
	f := startConnFake(t)
	c, err := Listen(2222)
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	if f.connectCalls != 1 || f.connectIP != 0 || f.connectPort != 2222 {
		t.Fatalf("connect = %d calls to %08x:%d, want 1 call to 0:2222",
			f.connectCalls, f.connectIP, f.connectPort)
	}
	if f.op10Calls != 0 || f.opsCalled(SockOpListen) != 0 {
		t.Fatal("vi.Listen took the handle path")
	}
	if !c.listening || c.Handle() != 0 {
		t.Fatal("legacy Listen must look handle-less")
	}
	if err := c.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if f.closeCalls != 1 {
		t.Fatalf("close calls = %d, want 1 slot-33", f.closeCalls)
	}
}

func TestListen_PortZeroRefused(t *testing.T) {
	f := startConnFake(t)
	if _, err := Listen(0); !errors.Is(err, error(errno(ErrEINVAL))) {
		t.Fatalf("Listen(0) = %v, want EINVAL", err)
	}
	if f.connectCalls != 0 {
		t.Fatal("Listen(0) reached the kernel")
	}
}

func TestSocketListen_MintsAHandle(t *testing.T) {
	f := startConnFake(t)
	ln, err := SocketListen(6001)
	if err != nil {
		t.Fatalf("SocketListen: %v", err)
	}
	if f.opsCalled(SockOpListen) != 1 {
		t.Fatalf("op-0 calls = %d, want 1", f.opsCalled(SockOpListen))
	}
	if ln.Handle() == 0 || !ln.listening {
		t.Fatal("SocketListen must return a handle listener")
	}
	if err := ln.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if f.opsCalled(SockOpClose) != 1 || f.opsCalled(SockOpShutdown) != 0 {
		t.Fatalf("listener close = %d close / %d shutdown, want 1 / 0",
			f.opsCalled(SockOpClose), f.opsCalled(SockOpShutdown))
	}
}

func TestSocketListen_TableFullIsConnBusy(t *testing.T) {
	f := startConnFake(t)
	f.listenErr = -ErrENOSPC
	if _, err := SocketListen(6001); !errors.Is(err, ErrConnBusy) {
		t.Fatalf("SocketListen on a full table = %v, want ErrConnBusy", err)
	}
}

func TestAccept_LegacyWaitsUntilEstablished(t *testing.T) {
	f := startConnFake(t)
	c, err := Listen(2222)
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	// First two probes still listening (mask 0); third is established
	// (writable bit 1). Accept must park between probes rather than
	// spinning, and must not touch recv.
	f.probeScript = func(call int) int64 {
		if call >= 3 {
			return 2
		}
		return 0
	}
	if err := c.Accept(); err != nil {
		t.Fatalf("Accept: %v", err)
	}
	if c.listening {
		t.Fatal("Accept left the Conn in listening state")
	}
	if f.probeCalls < 3 {
		t.Fatalf("probes = %d, want at least 3", f.probeCalls)
	}
	if f.sleeps < 2 {
		t.Fatalf("sleeps = %d, want parks between empty probes", f.sleeps)
	}
	if f.recvCalls != 0 {
		t.Fatalf("Accept recv'd %d times, want 0", f.recvCalls)
	}
}

func TestAcceptConn_PerHandleChild(t *testing.T) {
	f := startConnFake(t)
	ln, err := SocketListen(6001)
	if err != nil {
		t.Fatalf("SocketListen: %v", err)
	}
	child := f.mint(1)
	f.socks[ln.Handle()].pending = []uint64{child}
	conn, err := ln.AcceptConn()
	if err != nil {
		t.Fatalf("AcceptConn: %v", err)
	}
	if conn.Handle() != child {
		t.Fatalf("accepted handle = %x, want %x", conn.Handle(), child)
	}
	// The listener is still listening for the next SYN.
	if !ln.listening {
		t.Fatal("AcceptConn must not consume the listener")
	}
	// The child answers op-7 peer for IP/Port.
	if conn.IP() != [4]byte{10, 0, 0, 2} || conn.Port() != 8080 {
		t.Fatalf("accepted peer = %v:%d", conn.IP(), conn.Port())
	}
}

func TestAcceptConn_LegacyListenerRefuses(t *testing.T) {
	startConnFake(t)
	ln, _ := Listen(2222)
	if _, err := ln.AcceptConn(); !errors.Is(err, errno(ErrEINVAL)) {
		t.Fatalf("AcceptConn on the legacy listener = %v, want EINVAL", err)
	}
}

func TestAccept_BindsTheServingChild(t *testing.T) {
	f := startConnFake(t)
	ln, _ := SocketListen(6001)
	child := f.mint(1)
	f.socks[ln.Handle()].pending = []uint64{child}
	if err := ln.Accept(); err != nil {
		t.Fatalf("Accept: %v", err)
	}
	if ln.serve != child {
		t.Fatalf("serving handle = %x, want %x", ln.serve, child)
	}
	// I/O now rides the child handle.
	f.socks[child].readable = true
	f.readScript = func(h uint64, call int) ([]byte, int64) { return []byte("hi"), 2 }
	n, err := ln.Recv(make([]byte, 8))
	if err != nil || n != 2 {
		t.Fatalf("Recv via bound child = %d, %v", n, err)
	}
}

func TestSend_ChunksByConfirmedCounts(t *testing.T) {
	f := startConnFake(t)
	c, _ := Dial("10.0.0.2", 8080)
	f.socks[c.Handle()].writable = true
	body := make([]byte, 2*TCPPayloadMax+116)
	for i := range body {
		body[i] = byte(i)
	}
	n, err := c.Send(body)
	if err != nil || n != len(body) {
		t.Fatalf("Send = %d, %v want %d, nil", n, err, len(body))
	}
	if len(f.sentSizes) != 3 || f.sentSizes[0] != TCPPayloadMax || f.sentSizes[1] != TCPPayloadMax || f.sentSizes[2] != 116 {
		t.Fatalf("segment plan = %v", f.sentSizes)
	}
	for i := range body {
		if f.sentBytes[i] != byte(i) {
			t.Fatalf("sent byte %d = %d", i, f.sentBytes[i])
		}
	}
	if f.opsCalled(SockOpSend) != 3 {
		t.Fatalf("op-3 sends = %d, want 3", f.opsCalled(SockOpSend))
	}
}

func TestSend_ParksOnWouldBlock(t *testing.T) {
	// A full TX slot answers WouldBlock: the send parks one tick and
	// retries rather than spinning or failing.
	f := startConnFake(t)
	c, _ := Dial("10.0.0.2", 8080)
	calls := 0
	f.sockSendErr = map[uint64]int64{}
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotSocket && int(a0) == SockOpSend {
			calls++
			if calls == 1 {
				return -ErrEAGAIN
			}
		}
		return f.hook(num, a0, a1, a2, a3)
	})
	defer SetSyscallHookForTest(prev)
	n, err := c.Send([]byte("abc"))
	if err != nil || n != 3 {
		t.Fatalf("Send = %d, %v want 3, nil", n, err)
	}
	if f.sleeps != 1 {
		t.Fatalf("a WouldBlock send parked %d times, want 1", f.sleeps)
	}
}

func TestRecv_DeliversQueuedBytes(t *testing.T) {
	f := startConnFake(t)
	c, _ := Dial("10.0.0.2", 8080)
	f.socks[c.Handle()].readable = true
	f.readScript = func(h uint64, call int) ([]byte, int64) { return []byte("hello world"), 11 }
	buf := make([]byte, 64)
	n, err := c.Recv(buf)
	if err != nil || n != 11 || string(buf[:n]) != "hello world" {
		t.Fatalf("Recv = %d, %v, %q want 11, nil, hello world", n, err, buf[:n])
	}
	if f.opsCalled(SockOpRead) != 1 || f.opsCalled(SockOpReady) != 1 {
		t.Fatalf("recv = %d read / %d ready ops", f.opsCalled(SockOpRead), f.opsCalled(SockOpReady))
	}
}

func TestRecv_ParksWhileNotReadable(t *testing.T) {
	f := startConnFake(t)
	c, _ := Dial("10.0.0.2", 8080)
	f.readyScript = func(h uint64, call int) int64 {
		if call < 3 {
			return 0
		}
		return readyRead
	}
	f.readScript = func(h uint64, call int) ([]byte, int64) { return []byte("x"), 1 }
	n, err := c.Recv(make([]byte, 8))
	if err != nil || n != 1 {
		t.Fatalf("Recv = %d, %v want 1, nil", n, err)
	}
	if f.sleeps != 2 {
		t.Fatalf("parks = %d, want 2 (one per empty poll)", f.sleeps)
	}
}

func TestRecv_ReadableButEmptyIsPeerGone(t *testing.T) {
	f := startConnFake(t)
	c, _ := Dial("10.0.0.2", 8080)
	f.socks[c.Handle()].readable = true
	f.readScript = func(h uint64, call int) ([]byte, int64) { return nil, 0 }
	if _, err := c.Recv(make([]byte, 8)); !errors.Is(err, ErrPeerGone) {
		t.Fatalf("readable-but-empty Recv = %v, want ErrPeerGone", err)
	}
	calls := f.recvCalls
	if _, err := c.Recv(make([]byte, 8)); !errors.Is(err, ErrPeerGone) {
		t.Fatalf("Recv after peer gone = %v, want ErrPeerGone", err)
	}
	if f.recvCalls != calls {
		t.Fatal("Recv after peer gone must fail closed without a recv")
	}
}

func TestRecv_TimesOutWhenNeverReadable(t *testing.T) {
	f := startConnFake(t)
	c, _ := Dial("10.0.0.2", 8080)
	c.SetRecvDeadline(2_000_000) // 2 ms of real wall clock
	start := time.Now()
	_, err := c.Recv(make([]byte, 8))
	if !errors.Is(err, error(errno(ErrETIMEDOUT))) {
		t.Fatalf("Recv on a silent peer = %v, want Errno(ETIMEDOUT)", err)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("a 2 ms budget took %v — the wait is not bounded", elapsed)
	}
	if f.sleeps == 0 {
		t.Fatal("the bounded wait must park between probes, not spin")
	}
}

func TestRecv_ExpiredDeadlineFailsOnFirstProbe(t *testing.T) {
	f := startConnFake(t)
	c, _ := Dial("10.0.0.2", 8080)
	c.SetRecvDeadline((1 * time.Millisecond).Nanoseconds())
	time.Sleep(5 * time.Millisecond)
	_, err := c.Recv(make([]byte, 8))
	if !errors.Is(err, error(errno(ErrETIMEDOUT))) {
		t.Fatalf("Recv with an elapsed deadline = %v, want Errno(ETIMEDOUT)", err)
	}
	if f.readyCalls != 1 || f.sleeps != 0 {
		t.Fatalf("elapsed deadline cost %d probes / %d parks, want 1 / 0", f.readyCalls, f.sleeps)
	}
}

func TestRecv_ReadinessIsPerHandle(t *testing.T) {
	// The headline M99g semantic: Recv probes THIS conn's handle — a
	// sibling conn's readiness never answers for it.
	f := startConnFake(t)
	c1, _ := Dial("10.0.0.2", 8080)
	c2, _ := Dial("10.0.0.2", 8080)
	var probed []uint64
	f.readyScript = func(h uint64, call int) int64 {
		probed = append(probed, h)
		if h == c1.Handle() {
			return readyRead
		}
		return 0
	}
	f.readScript = func(h uint64, call int) ([]byte, int64) { return []byte("x"), 1 }
	c2.SetRecvDeadline(1_000_000) // 1 ms — bounded while sibling stays ready
	if n, err := c1.Recv(make([]byte, 8)); err != nil || n != 1 {
		t.Fatalf("c1 Recv = %d, %v", n, err)
	}
	if _, err := c2.Recv(make([]byte, 8)); !errors.Is(err, errno(ErrETIMEDOUT)) {
		t.Fatalf("c2 Recv = %v, want its own timeout (sibling readiness must not leak)", err)
	}
	seen1, seen2 := false, false
	for _, h := range probed {
		seen1 = seen1 || h == c1.Handle()
		seen2 = seen2 || h == c2.Handle()
	}
	if !seen1 || !seen2 {
		t.Fatalf("probed handles = %v — want both conns' own handles", probed)
	}
}

func TestClose_ReleasesTheHandle(t *testing.T) {
	f := startConnFake(t)
	c, _ := Dial("10.0.0.2", 8080)
	if err := c.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if f.opsCalled(SockOpShutdown) != 1 || f.opsCalled(SockOpClose) != 1 {
		t.Fatalf("close = %d shutdown / %d release, want 1/1",
			f.opsCalled(SockOpShutdown), f.opsCalled(SockOpClose))
	}
	if !f.socks[c.Handle()].shutdown || !f.socks[c.Handle()].closed {
		t.Fatal("the kernel did not see FIN-then-release")
	}
	if err := c.Close(); err != nil {
		t.Fatalf("double Close = %v, want nil", err)
	}
	if f.opsCalled(SockOpClose) != 1 {
		t.Fatal("the second Close must be a no-op")
	}
	if _, err := c.Recv(make([]byte, 8)); !errors.Is(err, ErrConnClosed) {
		t.Fatalf("Recv after Close = %v, want ErrConnClosed", err)
	}
	if _, err := c.Send([]byte("x")); !errors.Is(err, ErrConnClosed) {
		t.Fatalf("Send after Close = %v, want ErrConnClosed", err)
	}
}

func TestRecv_EmptyBufferIsNoop(t *testing.T) {
	f := startConnFake(t)
	c, _ := Dial("10.0.0.2", 8080)
	if n, err := c.Recv(nil); n != 0 || err != nil {
		t.Fatalf("Recv(nil) = %d, %v want 0, nil", n, err)
	}
	if f.recvCalls != 0 || f.opsCalled(SockOpRead) != 0 {
		t.Fatal("an empty recv must not touch the kernel")
	}
}

func TestSocketTable_ParsesRows(t *testing.T) {
	f := startConnFake(t)
	f.op12Rows = []SocketRow{
		{Owner: 7, LocalIP: [4]byte{10, 0, 0, 1}, LocalPort: 2222, Kind: 0},
		{Owner: 7, LocalIP: [4]byte{10, 0, 0, 1}, LocalPort: 2222,
			RemoteIP: [4]byte{10, 0, 0, 2}, RemotePort: 12345, Kind: 1, State: 1},
	}
	rows := SocketTable()
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2", len(rows))
	}
	if rows[0].Owner != 7 || rows[0].Kind != 0 || rows[0].LocalPort != 2222 {
		t.Fatalf("listener row = %+v", rows[0])
	}
	if rows[1].Kind != 1 || rows[1].State != 1 || rows[1].RemotePort != 12345 || rows[1].RemoteIP != [4]byte{10, 0, 0, 2} {
		t.Fatalf("conn row = %+v", rows[1])
	}
	if f.opsCalled(SockOpTable) != 1 {
		t.Fatalf("op-12 calls = %d, want 1", f.opsCalled(SockOpTable))
	}
}

func TestLegacyDialRawSlotsStillWork(t *testing.T) {
	// The kernel's legacy view binds the process's first active-open
	// conn — which a handle Dial still is — so raw slot 31/32/76 callers
	// keep their contract (they run before vsys's older Dial wrappers).
	f := startConnFake(t)
	c, _ := Dial("10.0.0.2", 8080)
	f.socks[c.Handle()].readable = true // for the fake's view; raw recv scripted below
	f.probeMask = 1
	f.recvScript = func(int) ([]byte, int64) { return []byte("ok"), 2 }
	mask, rc := TCPReady()
	if rc < 0 || mask != 1 {
		t.Fatalf("raw TCPReady = %d, %d", mask, rc)
	}
	buf := make([]byte, 8)
	n, rc := TCPRecv(buf)
	if rc < 0 || n != 2 {
		t.Fatalf("raw TCPRecv = %d, %d", n, rc)
	}
}
