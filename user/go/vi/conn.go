package vi

import (
	"errors"
	"time"
	"unsafe"

	"virelai/vsys"
)

// The M99g (#2185) per-handle socket surface: `vi.Dial` and the native
// `SocketListen`/`AcceptConn` pair ride the kernel's slot-80 socket ABI
// (kernel/src/syscall.zig handle_socket), where every Conn carries the
// generation-tagged table handle M99f (#2184) mints. The process's bound
// is the kernel table's own (owner_limit=4, conn_limit=4): a refused
// open comes back ENOSPC and maps to ErrConnBusy — there is no userland
// copy of the bound.
//
// Legacy compat: `vi.Listen` still takes the slot-30 passive open, so
// the singleton-era callers (agentd, rfbserver, httpd) that drive the
// accepted session over raw slots 31–33/76 keep their kernel contract.
// Raw-slot callers after a `vi.Dial` also keep working: the kernel's
// legacy view binds the process's first active-open conn, which an
// op-10 conn still is.
//
// Blocking semantics: Dial's connect waits IN the kernel (op 10 spins
// the caller until ESTABLISHED or the connect budget expires — the
// kernel drops the net domain lock through its pacing window, so two
// goroutines really can each hold a live connect); Recv is
// blocking-with-poll — probe the HANDLE's readiness mask (op 5), take
// the bytes when readable, otherwise check the deadline and PARK one
// scheduler tick (slot 4) before re-probing. A parked Recv therefore
// never starves its peers. Every wait is bounded (the deadline or
// DefaultRecvBudgetNs): a peer that goes dark fails closed instead of
// parking forever.

const (
	// TCPPayloadMax is tcp.payload_max (kernel/src/tcp.zig): the largest
	// single segment the seam accepts. Send chunks at this size.
	TCPPayloadMax = 1460
	// DefaultRecvBudgetNs is the bounded-wait ceiling used when no recv
	// deadline is set. An unbounded wait is deliberately not expressible.
	DefaultRecvBudgetNs = 30_000_000_000
	// maxRecvPolls is a belt-and-braces iteration bound: even with a clock
	// that never advances, the recv loop still terminates.
	maxRecvPolls = 3600
)

// Slot-80 socket ops (kernel/src/syscall.zig handle_socket dispatch).
// Exported so host-side test fakes in other packages (fetch, browser)
// key on the same numbers instead of mirroring them.
const (
	SockOpListen   = 0
	SockOpAccept   = 1
	SockOpRead     = 2
	SockOpSend     = 3
	SockOpClose    = 4
	SockOpReady    = 5
	SockOpShutdown = 6
	SockOpPeer     = 7
	SockOpConnect  = 10
	SockOpTable    = 12
)

// Slot-80's socket_error rows beyond the ADR 0007 generic table's 12:
// PeerReset and Closed are conn-terminal signals, not argument faults.
const (
	errSockPeerReset int64 = 13
	errSockClosed    int64 = 14
)

// Per-handle readiness mask bits (native_socket.ready).
const (
	readyRead     = 1 // data queued, peer FIN, or terminal
	readyWrite    = 2 // established and the bounded TX slot is free
	readyAccept   = 4 // listener: an established child awaits accept
	readyTerminal = 8 // conn reached its terminal state
)

// Connection-domain failures (the errno rows carry the kernel's codes; the
// sentinels carry this type's own contract).
var (
	// ErrConnBusy: the kernel's socket table refused the open — every
	// listener and connection the process holds charges the table's
	// per-owner bound, and the global conn limit is shared. Close a
	// socket before opening another.
	ErrConnBusy = errString("vi: TCP socket table full — Close a socket before opening another")
	// ErrConnClosed: the Conn was closed (or is nil) and cannot carry traffic.
	ErrConnClosed = errString("vi: connection closed")
	// ErrPeerGone: the peer's FIN/RST was observed. Fail closed, never spin.
	ErrPeerGone = errString("vi: peer closed the connection")
)

// ErrServerDial: a dial to the all-zeros address. The kernel treats
// ip == 0 as PASSIVE open (listen mode, kernel/src/syscall.zig
// handle_tcp_connect). Dial refuses the address in userland so a
// hostile DNS reply resolving to 0.0.0.0 cannot accidentally open a
// listener; Listen is the inbound path (M70g G1, #1491).
var ErrServerDial = errString("vi: 0.0.0.0 is the passive-open address — Dial refuses it; use Listen")

// ErrNameNoAddr: the name both families answered empty — the A query
// came back NODATA and the AAAA query had no usable record either
// (dialName's last stop). Distinct from ErrNameNotFound (NXDOMAIN
// propagates before the second question is asked) and from
// ErrServerDial (records existed; every one was undialable).
var ErrNameNoAddr = errString("vi: name has no A or AAAA record")

// errString is a constant error carried as a string (the mirror of vsys's
// sentinel style; the errno type covers kernel codes, these cover the
// userland contract).
type errString string

func (e errString) Error() string { return string(e) }

// Conn is one TCP connection or listener on the kernel's socket table.
// Create an outbound one with Dial/DialTimeout (it holds the op-10
// handle), a handle listener with SocketListen, or an accepted child
// with a handle listener's AcceptConn. `vi.Listen` still mints the
// legacy slot-30 listener for the singleton-era callers that drive the
// session over raw slots. A Conn's Recv/Send/Close are owned by one
// goroutine — the same contract vsys.Conn states — but separate Conns
// are independent: two goroutines can each run one.
type Conn struct {
	handle    uint64 // the table handle; 0 for the legacy slot-30 view
	serve     uint64 // a handle listener's bound serving child (Accept)
	ip        [4]byte
	ip6       [16]byte // the v6 literal Dial'd (v6 only)
	port      uint16
	v6        bool // the connection is family v6
	open      bool
	listening bool
	peerGone  bool
	// deadlineAt is an ABSOLUTE monotonic deadline in Nanos() nanoseconds
	// for Recv (0 = unset — DefaultRecvBudgetNs applies). Absolute, so a
	// budget shorter than one scheduler tick is not rounded up to a whole
	// tick and a late tick cannot stretch it.
	deadlineAt int64
}

// sock is the slot-80 gateway: args[0]=op, args[1]=handle-or-ip,
// args[2]=ptr-or-port, args[3]=len. Negative returns are the kernel's
// socket errnos. Slot 80's ABI takes SIX argument words — the kernel
// refuses nonzero args[4]/args[5], and svc4 would leave those registers
// holding whatever the caller last had there (a systematic EINVAL on
// target; the fake never sees it because the test hook is 4-arg). The
// hook path keeps the four meaningful words; the guest path zero-pads
// to six.
func sock(op uintptr, a1, a2, a3 uintptr) int64 {
	if syscallHook != nil {
		return syscallHook(SlotSocket, op, a1, a2, a3)
	}
	return syscall6(SlotSocket, op, a1, a2, a3, 0, 0)
}

// sockErr maps a refused slot-80 open to the named bound — Capacity is
// the kernel's honest "the table is full" and travels as ENOSPC (-5).
func sockErr(rc int64) error {
	if rc < 0 && -rc == ErrENOSPC {
		return ErrConnBusy
	}
	return errno(-rc)
}

// Dial connects to host:port. host may be a dotted-quad IPv4 literal
// (dialed directly), a v6 literal — bare `x::y` or bracketed `[x::y]`,
// M117c's tagged marshal (ADR 0057 D8/D10: never an IPv4-mapped
// translation) — or a name. A name resolves against DefaultDNSServer
// v4-first (dialName): an A answer dials v4 as it always has, and only
// an A answer with nothing dialable sends the AAAA question whose
// answer opens the same familyV6Tag socket a v6 literal does (M184a).
// The kernel's connect blocks until the handshake lands or its 30 s
// timeout expires; a refusal maps to the kernel's errno (ENOSPC ->
// ErrConnBusy by name).
func Dial(host string, port uint16) (*Conn, error) {
	return dial(host, port, 0)
}

// DialTimeout connects like Dial, but bounds the outbound handshake in the
// kernel by d. DNS resolution keeps its separate DefaultDNSBudgetNs budget.
// d must be positive and fit in uint32 milliseconds, rounded up to the next
// millisecond. Expiry returns Errno(ErrETIMEDOUT).
func DialTimeout(host string, port uint16, d time.Duration) (*Conn, error) {
	if d <= 0 {
		return nil, errno(ErrEINVAL)
	}
	ms := uint64(d / time.Millisecond)
	if d%time.Millisecond != 0 {
		ms++
	}
	if ms > 0xffffffff {
		return nil, errno(ErrEINVAL)
	}
	return dial(host, port, uint32(ms))
}

func dial(host string, port uint16, timeoutMs uint32) (*Conn, error) {
	if port == 0 {
		return nil, errno(ErrEINVAL)
	}
	if IsV6Literal(host) {
		addr, err := ParseIPv6(host)
		if err != nil {
			return nil, errno(ErrEINVAL)
		}
		return dial6(addr, port, timeoutMs)
	}
	ip, perr := vsys.ParseIPv4(host)
	if perr != nil {
		return dialName(host, port, timeoutMs)
	}
	if ip == ([4]byte{}) {
		return nil, ErrServerDial
	}
	return dial4(ip, port, timeoutMs)
}

// dialName is the hostname path, v4-first (M184a, #3174): the A
// question goes out first and a usable answer dials v4 exactly as it
// always has, so an A-only or dual-family name never pays a second
// question — no silent behavior change. Only when the A answer carries
// nothing a connect may use — the NODATA answer (ErrNoARecord) or an
// answer of nothing but the passive-open 0.0.0.0 — is the AAAA
// question sent; a usable answer then opens the same familyV6Tag
// socket the literal path uses. Server ordering is authoritative in
// both families: the FIRST record decides, and a leading undialable
// record is refused by name, never skipped for a later one. NXDOMAIN,
// refused sends, truncation and timeouts propagate from the A query
// unchanged: the name is absent or the wire is, and a second question
// would meet the same answer. When every answer was empty the refusal
// names the pair (ErrNameNoAddr); answers of nothing but undialable
// addresses stay refused by name (ErrServerDial).
//
// M184a app audit — what each networked app does with a v6-only host
// (a name whose only record is AAAA):
//   - fetch (user/go/fetch legacy.go dialPlain): rides vi.Dial — the
//     name now resolves AAAA and the conn goes out familyV6Tag.
//   - goirc (user/go/goirc dial.go dialGuest): plaintext rides vi.Dial
//     the same way; the TLS path is tls.Dial, which is vi.Dial plus
//     the handshake — reaches v6 identically.
//   - ssh (user/go/ssh main.go): rides vi.Dial — reaches v6; a refusal
//     prints its stage=connect line and exits the connect code.
//   - browser (user/go/browser network.go connectPage): ResolveDNS +
//     DialTimeout on the v4 literal — a v6-only host stops at
//     'web: dns-error dns: name has no A record': it cannot reach the
//     host, but the refusal names the missing family instead of a bare
//     resolution failure.
//   - httpd and the other vi.Listen/SocketListen servers: passive
//     opens — family-agnostic inbound, untouched by this path.
func dialName(host string, port uint16, timeoutMs uint32) (*Conn, error) {
	zeroA := false
	if res, err := Resolve(host, DefaultDNSServer, DNSQueryA, 0); err == nil {
		if v4 := firstAAddr(res); v4 != ([4]byte{}) {
			return dial4(v4, port, timeoutMs)
		}
		zeroA = true // answered, only the undialable zero address
	} else if !errors.Is(err, ErrNoARecord) {
		return nil, err
	}
	res6, err := Resolve(host, DefaultDNSServer, DNSQueryAAAA, 0)
	if err == nil {
		if v6 := firstAAAAAddr(res6); !isBadV6Dst(v6) {
			return dial6(v6, port, timeoutMs)
		}
		// Answered, only undialable destinations — the same refusal
		// family as the v4 passive-open zero.
		return nil, ErrServerDial
	}
	if !errors.Is(err, ErrNoAAAARecord) {
		return nil, err
	}
	if zeroA {
		return nil, ErrServerDial
	}
	return nil, ErrNameNoAddr
}

// firstAAddr is the first A record of an A-query result — the same
// pick ResolveDNS has always made. firstAAAAAddr is its v6 twin. (A
// result's Addrs are all of the asked family by construction.)
func firstAAddr(res DNSResult) [4]byte {
	for _, a := range res.Addrs {
		if !a.V6 {
			return a.IPv4
		}
	}
	return [4]byte{}
}

func firstAAAAAddr(res DNSResult) [16]byte {
	for _, a := range res.Addrs {
		if a.V6 {
			return a.IPv6
		}
	}
	return [16]byte{}
}

// dial4 / dial6 are the two family marshals of op 10: v4 rides the
// register word, v6 the family tag plus the 16-byte copy-in seam.
func dial4(ip [4]byte, port uint16, timeoutMs uint32) (*Conn, error) {
	rc := sock(SockOpConnect, ipv4Word(ip), uintptr(port)|uintptr(timeoutMs)<<16, 0)
	if rc < 0 {
		return nil, sockErr(rc)
	}
	return &Conn{handle: uint64(rc), ip: ip, port: port, open: true}, nil
}

func dial6(addr [16]byte, port uint16, timeoutMs uint32) (*Conn, error) {
	rc := sock(SockOpConnect, familyV6Tag, uintptr(port)|uintptr(timeoutMs)<<16, bytePtr(addr[:]))
	if rc < 0 {
		return nil, sockErr(rc)
	}
	return &Conn{handle: uint64(rc), v6: true, ip6: addr, port: port, open: true}, nil
}

// Listen passively opens port on the LEGACY slot-30 view (ip==0): the
// shim's accepted children ride raw slots 31–33/76, which is what
// agentd, rfbserver and httpd's session loops still drive. New
// handle-mode servers take SocketListen instead. Accept waits until
// that handshake reaches ESTABLISHED. Close releases the process's
// legacy socket so the next Listen or Dial can run.
func Listen(port uint16) (*Conn, error) {
	if port == 0 {
		return nil, errno(ErrEINVAL)
	}
	rc := svc2(SlotTCPConnect, 0, uintptr(port))
	if rc < 0 {
		return nil, sockErr(rc)
	}
	return &Conn{port: port, open: true, listening: true}, nil
}

// SocketListen passively opens port on the slot-80 handle ABI (op 0):
// the returned listener is a real table socket with its own handle, so
// one process may hold it alongside Dial'd connections and accepted
// children — that is the server shape the singleton kernel could not
// express. Its children are claimed per-handle with AcceptConn (each a
// fully independent Conn), or bound to the listener itself with Accept
// for the legacy single-session callers.
func SocketListen(port uint16) (*Conn, error) {
	if port == 0 {
		return nil, errno(ErrEINVAL)
	}
	rc := sock(SockOpListen, 0, uintptr(port), 0)
	if rc < 0 {
		return nil, sockErr(rc)
	}
	return &Conn{handle: uint64(rc), port: port, open: true, listening: true}, nil
}

// Handle returns the kernel's generation-tagged table handle (0 for the
// legacy view). Exposed for observability — the netstat table dump
// prints the same handles.
func (c *Conn) Handle() uint64 {
	if c == nil {
		return 0
	}
	return c.handle
}

// Accept waits until the listened socket has an ESTABLISHED session to
// serve. On the legacy listener it parks on slot-76 readiness exactly as
// before (the raw slots then serve the child). On a handle listener it
// claims the pending child itself (op 1) and binds it as the Conn's
// serving socket — Send/Recv/ReadyMask then run per-handle on that
// child. A bounded wait fails closed rather than parking forever.
func (c *Conn) Accept() error {
	if c == nil || !c.open {
		return ErrConnClosed
	}
	if !c.listening {
		return nil
	}
	if c.handle == 0 {
		deadline := Nanos() + DefaultRecvBudgetNs
		for polls := 0; ; polls++ {
			mask, rc := TCPReady()
			if rc < 0 {
				if -rc == ErrEAGAIN {
					return ErrConnClosed
				}
				return errno(-rc)
			}
			// Established (writable) or the peer already sent bytes/FIN.
			if mask&3 != 0 {
				c.listening = false
				return nil
			}
			if Nanos() >= deadline || polls >= maxRecvPolls {
				return errno(ErrETIMEDOUT)
			}
			svc1(SlotSleep, 1)
		}
	}
	if c.serve != 0 {
		return nil // a serving child is already bound
	}
	child, err := c.AcceptConn()
	if err != nil {
		return err
	}
	c.serve = child.handle
	return nil
}

// AcceptConn claims the listener's next ESTABLISHED child as its own
// Conn — the multi-session accept: every call hands back an independent
// per-handle connection while the listener stays live for the next SYN.
// Only a SocketListen listener can hand out handles; on the legacy
// listener the children already belong to the raw slots (EINVAL).
func (c *Conn) AcceptConn() (*Conn, error) {
	if c == nil || !c.open {
		return nil, ErrConnClosed
	}
	if c.handle == 0 || !c.listening {
		return nil, errno(ErrEINVAL)
	}
	deadline := Nanos() + DefaultRecvBudgetNs
	for polls := 0; ; polls++ {
		// The probe is the LISTENER's own readiness (readyAccept), never a
		// bound serving child's — AcceptConn must keep claiming while
		// another session is already being served.
		mask, rc := func() (int64, int64) {
			r := sock(SockOpReady, uintptr(c.handle), 0, 0)
			if r < 0 {
				return 0, r
			}
			return r, 0
		}()
		if rc < 0 {
			return nil, errno(-rc)
		}
		if mask&readyAccept != 0 {
			h := sock(SockOpAccept, uintptr(c.handle), 0, 0)
			if h < 0 {
				return nil, sockErr(h)
			}
			child := &Conn{handle: uint64(h), open: true}
			child.fillPeer()
			return child, nil
		}
		if Nanos() >= deadline || polls >= maxRecvPolls {
			return nil, errno(ErrETIMEDOUT)
		}
		svc1(SlotSleep, 1)
	}
}

// fillPeer snapshots the remote endpoint through op 7 so IP/Port answer
// without another syscall.
func (c *Conn) fillPeer() {
	r := sock(SockOpPeer, uintptr(c.handle), 0, 0)
	if r < 0 {
		return
	}
	w := uint64(r)
	c.ip = [4]byte{byte(w >> 40), byte(w >> 32), byte(w >> 24), byte(w >> 16)}
	c.port = uint16(w & 0xffff)
}

// IP returns the peer's address (the resolved one when Dial was given a
// name). Port returns the peer's port.
func (c *Conn) IP() [4]byte {
	if c == nil {
		return [4]byte{}
	}
	return c.ip
}

// IsV6 reports whether the connection is IPv6 (M117c — a literal Dial).
// IP6 returns the peer's v6 address (the [4]byte IP word cannot carry
// it; for a v4 conn IP6 is zero and IsV6 false).
func (c *Conn) IsV6() bool {
	return c != nil && c.v6
}

func (c *Conn) IP6() [16]byte {
	if c == nil {
		return [16]byte{}
	}
	return c.ip6
}

// Port returns the peer's port.
func (c *Conn) Port() uint16 {
	if c == nil {
		return 0
	}
	return c.port
}

// SetRecvDeadline bounds a blocking Recv by a monotonic budget in
// nanoseconds, measured on Nanos. ns <= 0 clears the deadline and restores
// DefaultRecvBudgetNs. A bounded recv is what makes a peer that goes dark
// fail closed instead of parking forever.
func (c *Conn) SetRecvDeadline(ns int64) {
	if c == nil {
		return
	}
	if ns <= 0 {
		c.deadlineAt = 0
		return
	}
	c.deadlineAt = Nanos() + ns
}

// readyProbe is the per-handle readiness poll: op 5 on the Conn's own
// handle (or its bound serving child), slot 76 on the legacy view.
// Returns (mask, negative-rc): one of the pair is always zero.
func (c *Conn) readyProbe() (int64, int64) {
	h := c.trafficHandle()
	if h == 0 {
		return TCPReady()
	}
	if r := sock(SockOpReady, uintptr(h), 0, 0); r < 0 {
		return 0, r
	} else {
		return r, 0
	}
}

// ReadyMask reports the Conn's current readiness bits (readyRead/
// readyWrite/readyAccept/readyTerminal) — per handle, so one Conn's
// probe never answers for another.
func (c *Conn) ReadyMask() (int64, error) {
	if c == nil || !c.open {
		return 0, ErrConnClosed
	}
	mask, rc := c.readyProbe()
	if rc < 0 {
		if -rc == ErrEAGAIN {
			return 0, ErrConnClosed
		}
		return 0, errno(-rc)
	}
	return mask, nil
}

// Send writes ALL of p, chunked to TCPPayloadMax (the kernel's one-segment
// bound) and advancing ONLY by the confirmed count each op-3/slot-31 call
// reports — the FileWriteAll contract applied to the socket, so a longer
// body is a run of honest syscalls that can never silently truncate.
// On a handle conn a WouldBlock answer means the bounded TX slot or the
// peer's window is full: park one tick and retry, bounded by the recv
// deadline's budget so a dead peer cannot wedge the sender.
// Returns the confirmed total (== len(p) on success, the confirmed prefix
// after a mid-stream failure).
func (c *Conn) Send(p []byte) (int, error) {
	if c == nil || !c.open {
		return 0, ErrConnClosed
	}
	if c.peerGone {
		return 0, ErrPeerGone
	}
	sent := 0
	deadline := Nanos() + DefaultRecvBudgetNs
	for sent < len(p) {
		take := len(p) - sent
		if take > TCPPayloadMax {
			take = TCPPayloadMax
		}
		var r int64
		if h := c.trafficHandle(); h != 0 {
			r = sock(SockOpSend, uintptr(h), bytePtr(p[sent:sent+take]), uintptr(take))
		} else {
			r = svc2(SlotTCPSend, bytePtr(p[sent:sent+take]), uintptr(take))
		}
		if r < 0 {
			if -r == ErrEAGAIN {
				if Nanos() >= deadline {
					return sent, errno(ErrETIMEDOUT)
				}
				svc1(SlotSleep, 1)
				continue
			}
			if e := c.deadErr(r); e != nil {
				return sent, e
			}
			return sent, errno(-r)
		}
		if r == 0 {
			// A zero-count acceptance cannot advance the stream; refuse
			// instead of spinning (the kernel never reports one for a
			// non-empty segment, so this is a defensive stop).
			return sent, errno(ErrEINVAL)
		}
		sent += int(r)
	}
	return sent, nil
}

// deadErr translates the kernel's dead-conn rows to the named sentinels:
// PeerReset and Closed mean the socket cannot carry bytes, not a
// caller-side argument fault.
func (c *Conn) deadErr(rc int64) error {
	switch -rc {
	case errSockPeerReset:
		c.peerGone = true
		return ErrPeerGone
	case errSockClosed, ErrEBADF:
		return ErrConnClosed
	}
	return nil
}

// trafficHandle is the handle the send/recv ops address: the bound
// serving child on an Accept'd handle listener, else the Conn's own.
func (c *Conn) trafficHandle() uint64 {
	if c.serve != 0 {
		return c.serve
	}
	return c.handle
}

// Recv reads up to len(p) bytes, blocking-with-poll: probe THIS
// connection's readiness (op 5 — a per-handle probe, so sibling
// connections never answer for it), take the segment when readable,
// otherwise check the deadline and park one scheduler tick (slot 4)
// before re-probing. A readable socket whose recv then drains 0 bytes
// means the peer's FIN/RST was consumed — fail closed with ErrPeerGone.
func (c *Conn) Recv(p []byte) (int, error) {
	if c == nil || !c.open {
		return 0, ErrConnClosed
	}
	if c.peerGone {
		return 0, ErrPeerGone
	}
	if len(p) == 0 {
		return 0, nil
	}
	max := len(p)
	if max > TCPPayloadMax {
		max = TCPPayloadMax
	}
	deadline := c.deadlineAt
	if deadline == 0 {
		deadline = Nanos() + DefaultRecvBudgetNs
	}
	for polls := 0; ; polls++ {
		mask, rc := c.readyProbe()
		if rc < 0 {
			// EAGAIN = the process owns no socket any more (released or
			// never connected): the Conn is dead, not merely empty.
			if -rc == ErrEAGAIN {
				return 0, ErrConnClosed
			}
			if e := c.deadErr(rc); e != nil {
				return 0, e
			}
			return 0, errno(-rc)
		}
		if mask&readyRead != 0 {
			var r int64
			if h := c.trafficHandle(); h != 0 {
				r = sock(SockOpRead, uintptr(h), bytePtr(p[:max]), uintptr(max))
			} else {
				r = svc2(SlotTCPRecv, bytePtr(p[:max]), uintptr(max))
			}
			if r < 0 {
				if -r == ErrEAGAIN {
					continue // readiness raced a drain: re-probe
				}
				if e := c.deadErr(r); e != nil {
					return 0, e
				}
				return 0, errno(-r)
			}
			if r == 0 {
				c.peerGone = true
				return 0, ErrPeerGone
			}
			return int(r), nil
		}
		// An already-expired budget fails on the FIRST probe instead of
		// paying a full tick for it.
		if Nanos() >= deadline || polls >= maxRecvPolls {
			return 0, errno(ErrETIMEDOUT)
		}
		// The park point: one scheduler tick, so other goroutines run. The
		// loop resumes, re-probes, and re-checks the deadline.
		svc1(SlotSleep, 1)
	}
}

// Close tears the connection down. On a handle conn it first queues the
// graceful FIN (op 6, bounded retries while the TX slot is busy) and
// then releases the table slot (op 4). On a SocketListen listener the
// release also reclaims every child the listener spawned. On the legacy
// view it is slot 33 as before. Close on an already-closed (or nil)
// Conn is a no-op.
func (c *Conn) Close() error {
	if c == nil || !c.open {
		return nil
	}
	if c.handle == 0 && c.serve == 0 {
		rc := svc0(SlotTCPClose)
		if rc < 0 {
			return errno(-rc)
		}
		c.open = false
		return nil
	}
	if c.serve != 0 {
		finRelease(c.serve, true) // the bound serving child: FIN, then free
		c.serve = 0
	}
	if c.handle != 0 {
		finRelease(c.handle, !c.listening)
	}
	c.open = false
	return nil
}

// finRelease queues FIN on h when graceful (bounded while the TX slot
// stays busy or the conn has nothing established to close) and frees the
// handle. Release is unconditional: a FIN that could not queue still
// leaves an honestly-closed table slot.
func finRelease(h uint64, graceful bool) {
	if graceful {
		for polls := 0; polls < 300; polls++ {
			if r := sock(SockOpShutdown, uintptr(h), 0, 0); r != -ErrEAGAIN {
				break
			}
			svc1(SlotSleep, 1)
		}
	}
	_ = sock(SockOpClose, uintptr(h), 0, 0)
}

// SocketRow is one live socket-table row (the op-12 snapshot): a
// listener or a connection with its owner pid, so a reader can name the
// holding process.
type SocketRow struct {
	Owner      uint64
	LocalIP    [4]byte
	LocalPort  uint16
	RemotePort uint16
	RemoteIP   [4]byte
	Kind       uint8 // 0 = listener, 1 = connection
	State      uint8 // core State for connections (0 half-open, 1 established, 2 closing, 3 terminal)
}

// SocketTableMax bounds one snapshot (the kernel's own bound is far
// smaller; this only sizes the EL0 scratch buffer).
const SocketTableMax = 64
const socketRowLen = 24

// SocketTable snapshots the kernel's live socket table (op 12): every
// listener and every connection with its owner pid. Returns nil when
// the table is empty or the probe fails — observability, never a
// caller-blocking path.
func SocketTable() []SocketRow {
	buf := make([]byte, SocketTableMax*socketRowLen)
	n := sock(SockOpTable, bytePtr(buf), uintptr(SocketTableMax), 0)
	if n <= 0 {
		return nil
	}
	if n > SocketTableMax {
		n = SocketTableMax
	}
	rows := make([]SocketRow, 0, n)
	for i := int64(0); i < n; i++ {
		b := buf[i*socketRowLen:]
		rows = append(rows, SocketRow{
			Owner:      uint64(b[0]) | uint64(b[1])<<8 | uint64(b[2])<<16 | uint64(b[3])<<24 | uint64(b[4])<<32 | uint64(b[5])<<40 | uint64(b[6])<<48 | uint64(b[7])<<56,
			LocalIP:    [4]byte{b[8], b[9], b[10], b[11]},
			LocalPort:  uint16(b[12]) | uint16(b[13])<<8,
			RemotePort: uint16(b[14]) | uint16(b[15])<<8,
			RemoteIP:   [4]byte{b[16], b[17], b[18], b[19]},
			Kind:       b[20],
			State:      b[21],
		})
	}
	return rows
}

// ipv4Word packs an IPv4 address into the slot-30/10 argument word
// (big-endian in the low 32 bits — the kernel extracts the octets
// byte-explicitly, never a bitcast).
func ipv4Word(ip [4]byte) uintptr {
	return uintptr(uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3]))
}

// bytePtr is the &b[0] gateway for a non-empty byte slice (0 for empty —
// the kernel refuses a bad pointer, and an empty call has nothing to copy).
func bytePtr(b []byte) uintptr {
	if len(b) == 0 {
		return 0
	}
	return uintptr(unsafe.Pointer(&b[0]))
}
