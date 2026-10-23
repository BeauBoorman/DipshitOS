package vi

import (
	"bytes"
	"errors"
	"sync"
)

// DNS resolution from Go (M67a, #1446; depth pass M99i, #2187).
//
// The kernel's own resolver (kernel/src/dns.zig) is an EL1 singleton the
// monitor drives (`net dns`); no syscall reaches it. This file speaks
// RFC 1035 itself over the OWNED UDP seam M99i added for it:
//
//   - slot 9 binds a listen port, now owned by the binding process: only
//     that owner may recv (slot 11/85) or close (slot 86) it, and the
//     kernel reclaims the seat if the owner exits. A duplicate bind is
//     EINVAL (retry a fresh port), an exhausted table ENOSPC.
//   - slot 84 sends ONE datagram from an EXPLICIT source port that must
//     be bound by the caller — each transaction picks an ephemeral port,
//     binds it, sends, polls, closes. Two resolvers (two processes or two
//     goroutines) cannot consume each other's replies: a datagram lands
//     on the bound port and only the owner reads it.
//   - slot 85 copies the oldest datagram out prefixed with the sender's
//     IPv4 address (4-byte prefix + the 8-byte UDP header + payload), so
//     the client rejects a reply that did not come from the server it
//     asked — the spoof check the fixed-port path could not express.
//   - payload_max is 512: a query that does not fit is REFUSED before
//     any syscall, never truncated into the wire, and a 512-byte answer
//     is received whole.
//   - slot 84 does NOT resolve ARP (.no_peer → EINVAL): resolve-then-retry
//     stays the CALLER's contract. ErrDNSRefused surfaces that send
//     refusal; this client never retries it behind the caller's back.
//   - the query ID comes from the kernel CSPRNG (slot 72 via Random) —
//     never from the clock or a counter, both of which a same-tick retry
//     or a second process could reproduce.
//
// The LEGACY seam (slot 10's fixed source port 7000, slot 11's header-
// only receive, the 64-byte wrapper bound) is unchanged below for
// timesync and the old one-shot clients.

const (
	// DNSPort is the well-known resolver port the query is sent to.
	DNSPort = 53
	// udpSourcePort is udp.default_src_port: slot 10 always sends from
	// here, so it is also the port legacy replies arrive on.
	udpSourcePort = 7000
	// udpPayloadMax is the legacy wrapper's bound (slot 10 accepts more
	// since M99i raised the kernel bound to 512; the exported
	// UDPPayloadMax pins the 64-byte contract timesync was written
	// against, and the wrapper refuses beyond it up front).
	udpPayloadMax = 64
	// udpDatagramMax is the legacy slot-11 bound the same way.
	udpDatagramMax = 72
	// udpFromPayloadMax is the owned seam's payload bound (udp.payload_max).
	udpFromPayloadMax = 512
	// udpRecvFromMax is slot 85's copy-out bound: the 4-byte source IP
	// prefix + the 8-byte UDP header + payload (udp.recv_from_max).
	udpRecvFromMax = 4 + 8 + udpFromPayloadMax
	// The ephemeral range each DNS transaction draws its source port from
	// (the kernel socket layer's own ephemeral_lo/span, used here by the
	// client side — the bind still goes through the table).
	dnsEphemeralLo   = 49152
	dnsEphemeralSpan = 16384
	// dnsBindTries bounds the bind-retry loop on an ephemeral collision
	// (EINVAL). A full table is ENOSPC and fails immediately.
	dnsBindTries = 8
	// DefaultDNSBudgetNs bounds one resolution. A resolution that outlives
	// its budget fails closed (ETIMEDOUT), never blocks forever.
	DefaultDNSBudgetNs = 30_000_000_000
)

// DefaultDNSServer is the reference VM's resolver: the host gateway the
// runner's --net-dns-respond answers on. The kernel keeps no DHCP-learned
// server, so a program with a different resolver re-points this.
var DefaultDNSServer = [4]byte{10, 0, 0, 2}

// The QTYPEs the resolver asks for (RFC 1035 §3.2.2). Only A and AAAA are
// implemented — anything else is the caller's error to make, not this
// file's to encode.
const (
	DNSQueryA    uint16 = 1
	DNSQueryAAAA uint16 = 28
)

// DNS-domain failures. They are userland protocol conditions, not kernel
// errnos — distinct sentinels so a caller can branch on what happened.
var (
	// ErrNameTooLong: the encoded query would not fit one datagram
	// (udpFromPayloadMax). Refused before any syscall.
	ErrNameTooLong = errString("dns: name does not fit one UDP datagram")
	// ErrNameNotFound: the server answered NXDOMAIN (rcode 3).
	ErrNameNotFound = errString("dns: name not found (NXDOMAIN)")
	// ErrDNSTruncated: the reply arrived with TC=1 — the answer did not
	// fit one datagram. There is no TCP fallback (M99i deferral): the
	// refusal is honest, never a guess from a partial message.
	ErrDNSTruncated = errString("dns: reply truncated (TC=1) — no TCP fallback")
	// ErrDNSFailed: any other rcode or a malformed reply.
	ErrDNSFailed = errString("dns: resolution failed")
	// ErrNoARecord / ErrNoAAAARecord: a NOERROR answer (rcode 0) that
	// carried no usable record of the asked family — the name exists,
	// this family is empty for it (an AAAA-only host answers A with
	// NODATA). Named apart from ErrNameNotFound (NXDOMAIN — the name
	// itself is absent) and ErrDNSFailed (rcodes and malformed wire)
	// so a Dial caller asks the other family on exactly this answer
	// and an app's error names the missing family.
	ErrNoARecord    = errString("dns: name has no A record")
	ErrNoAAAARecord = errString("dns: name has no AAAA record")
	// ErrDNSRefused: the transport refused the send (EINVAL — the seam's
	// .no_peer/.not_ready mapping, usually the server's MAC missing from
	// ARP). The caller resolves (monitor `net arp <ip>`) and retries.
	ErrDNSRefused = errString("dns: send refused — resolve the peer first, then retry")
)

// errNotOurs marks a received datagram that is not our reply (wrong
// source IP, wrong source port, wrong ID, wrong echoed question, not a
// response): consumed, counted in DNSResult.Ignored, poll keeps going.
var errNotOurs = errors.New("dns: not our reply")

// DNSAddr is one usable address an answer section carried: IPv4 for an
// A query, IPv6 for AAAA (asked over IPv4 transport — the record type,
// not the link, decides).
type DNSAddr struct {
	V6   bool
	IPv4 [4]byte
	IPv6 [16]byte
}

// DNSResult reports one finished lookup, from the wire or the cache.
type DNSResult struct {
	// Addrs are the usable records of the asked family, first-usable
	// first, bounded at dnsAddrsMax even when the section carried more
	// (Answers still counts every record walked).
	Addrs []DNSAddr
	// TTLNs is the smallest TTL among the returned records, clamped to
	// [5s, 1h]. On a cache hit it is the entry's remaining lifetime.
	TTLNs int64
	// Answers is the header's ANCOUNT — every answer walked, usable or
	// not (a CNAME chain inside the section counts too).
	Answers int
	// Ignored counts datagrams consumed on the bound port that failed
	// the reply checks — wrong source IP, wrong source port, wrong ID,
	// wrong echoed question, or not a response. A nonzero value is the
	// transaction's spoof/noise report.
	Ignored int
	// Cached is true when the result came from the per-process TTL
	// cache: no bind, no query, no datagram touched the seam.
	Cached bool
}

// UDPListen binds port in the kernel's listen table, owned by the calling
// process (slot 9). Returns 0, -EINVAL (port 0/over-range/already bound),
// or -ENOSPC (the four-slot table is full).
func UDPListen(port uint16) int64 { return svc1(SlotUDPListen, uintptr(port)) }

// UDPSend sends ONE datagram to ip:port from the fixed source port (slot
// 10). Returns the payload length sent, or a negative errno. The wrapper
// keeps the 64-byte refusal it was written with — the kernel accepts
// more since M99i, but every client of this path was sized for 64 and
// the bound stays honest for them.
func UDPSend(ip [4]byte, port uint16, b []byte) int64 {
	if len(b) == 0 {
		return 0
	}
	if len(b) > udpPayloadMax {
		return -ErrEINVAL
	}
	return svc4(SlotUDPSend, ipv4Word(ip), uintptr(port), bytePtr(b), uintptr(len(b)))
}

// UDPRecv copies the oldest datagram for the listener on port OUT (slot
// 11): the full 8-byte UDP header + payload. Only the port's owner may
// read it (M99i). Returns the copied length (0 = ring empty) or a
// negative errno (-EACCES when another process owns the port).
func UDPRecv(port uint16, buf []byte) int64 {
	if len(buf) == 0 {
		return 0
	}
	return svc3(SlotUDPRecv, uintptr(port), bytePtr(buf), uintptr(min(len(buf), udpDatagramMax)))
}

// UDPSendFrom sends ONE datagram to ip:dstPort from the EXPLICIT source
// port srcPort, which must be bound in the listen table by the caller
// (slot 84). Unbound → -EINVAL, another owner's → -EACCES. Returns the
// payload length sent, or a negative errno; the payload refuses beyond
// udpFromPayloadMax before any syscall.
func UDPSendFrom(ip [4]byte, dstPort, srcPort uint16, b []byte) int64 {
	if len(b) == 0 {
		return 0
	}
	if len(b) > udpFromPayloadMax {
		return -ErrEINVAL
	}
	return svc6(SlotUDPSendFrom, ipv4Word(ip), uintptr(dstPort), uintptr(srcPort), bytePtr(b), uintptr(len(b)), 0)
}

// UDPRecvFrom copies the oldest datagram for the listener on port OUT
// (slot 85): a 4-byte source-IPv4 prefix, then the 8-byte UDP header and
// the payload — the shape the resolver's spoof check needs. Same
// ownership rule and the same empty-ring 0 as slot 11.
func UDPRecvFrom(port uint16, buf []byte) int64 {
	if len(buf) == 0 {
		return 0
	}
	return svc3(SlotUDPRecvFrom, uintptr(port), bytePtr(buf), uintptr(min(len(buf), udpRecvFromMax)))
}

// UDPClose releases a listen-table port the caller owns (slot 86):
// unbound → -EINVAL, another owner's → -EACCES, 0 on release. A process
// that exits without closing is reclaimed by the kernel's stale-owner
// scan at the next bind.
func UDPClose(port uint16) int64 { return svc1(SlotUDPClose, uintptr(port)) }

// Resolve resolves name against server for the asked family
// (DNSQueryA / DNSQueryAAAA) over the owned UDP seam. budgetNs <= 0
// means DefaultDNSBudgetNs. The wait is the same blocking-with-poll
// shape as Conn.Recv: probe the ring, check the deadline, park one
// scheduler tick, repeat.
//
// Each call is one transaction: a fresh ephemeral source port, a CSPRNG
// query ID, the reply validated against the queried server's address,
// the echoed question, and every answer walked. The bounded per-process
// TTL cache answers repeat lookups without touching the wire.
//
// A send refusal (ErrDNSRefused) is NOT retried: per the seam the
// caller resolves the peer (monitor `net arp <server>`) and retries.
func Resolve(name string, server [4]byte, qtype uint16, budgetNs int64) (DNSResult, error) {
	if qtype != DNSQueryA && qtype != DNSQueryAAAA {
		return DNSResult{}, errno(ErrEINVAL)
	}
	if r, ok := dnsCacheGet(name, server, qtype); ok {
		return r, nil
	}
	query, id, err := buildDNSQuery(name, qtype)
	if err != nil {
		return DNSResult{}, err
	}

	// Bind the reply port BEFORE the query goes out: an unbound port
	// drops the reply, and only this process's own port can deliver it.
	port, err := dnsBindEphemeral()
	if err != nil {
		return DNSResult{}, err
	}
	defer UDPClose(port)

	// One query, honestly refused or honestly sent.
	if rc := UDPSendFrom(server, DNSPort, port, query); rc < 0 {
		if -rc == ErrEINVAL {
			return DNSResult{}, ErrDNSRefused
		}
		return DNSResult{}, errno(-rc)
	}

	if budgetNs <= 0 {
		budgetNs = DefaultDNSBudgetNs
	}
	deadline := Nanos() + budgetNs
	buf := make([]byte, udpRecvFromMax)
	ignored := 0
	for polls := 0; ; polls++ {
		n := UDPRecvFrom(port, buf)
		if n < 0 {
			return DNSResult{}, errno(-n)
		}
		if n > 0 {
			res, perr := parseDNSReply(buf[:n], server, id, query[12:], qtype)
			switch {
			case perr == nil:
				res.Ignored = ignored
				dnsCachePut(name, server, qtype, res)
				return res, nil
			case errors.Is(perr, errNotOurs):
				ignored++
			default:
				return DNSResult{}, perr
			}
		}
		if Nanos() >= deadline || polls >= maxRecvPolls {
			return DNSResult{}, errno(ErrETIMEDOUT)
		}
		svc1(SlotSleep, 1)
	}
}

// ResolveDNS resolves name to its first IPv4 A record via server — the
// M67a entry point, kept for existing callers. The richer Resolve
// carries AAAA, the answer count, TTL, and the ignored/spoof report.
func ResolveDNS(name string, server [4]byte, budgetNs int64) ([4]byte, error) {
	r, err := Resolve(name, server, DNSQueryA, budgetNs)
	if err != nil {
		return [4]byte{}, err
	}
	for _, a := range r.Addrs {
		if !a.V6 {
			return a.IPv4, nil
		}
	}
	return [4]byte{}, ErrNoARecord
}

// ResolveDNS6 resolves name to its first IPv6 AAAA record via server —
// the v6 twin of ResolveDNS (M184a, #3174). An AAAA-only name is
// exactly this call's case; a name with no AAAA record comes back
// ErrNoAAAARecord by name.
func ResolveDNS6(name string, server [4]byte, budgetNs int64) ([16]byte, error) {
	r, err := Resolve(name, server, DNSQueryAAAA, budgetNs)
	if err != nil {
		return [16]byte{}, err
	}
	for _, a := range r.Addrs {
		if a.V6 {
			return a.IPv6, nil
		}
	}
	return [16]byte{}, ErrNoAAAARecord
}

// dnsBindEphemeral binds a CSPRNG-drawn ephemeral port for this
// transaction. A collision (EINVAL — the port is already bound, by this
// process or another) retries with a fresh draw up to dnsBindTries; a
// full table (ENOSPC) fails immediately because retries cannot open a
// seat. The caller closes the port when the transaction ends.
func dnsBindEphemeral() (uint16, error) {
	var draw [2]byte
	for tries := 0; tries < dnsBindTries; tries++ {
		if _, err := Random(draw[:]); err != nil {
			return 0, err
		}
		port := uint16(dnsEphemeralLo) + uint16((uint32(draw[0])<<8|uint32(draw[1]))%dnsEphemeralSpan)
		switch rc := UDPListen(port); {
		case rc == 0:
			return port, nil
		case -rc == ErrENOSPC:
			return 0, errno(ErrENOSPC)
		}
	}
	return 0, errno(ErrENOSPC)
}

// buildDNSQuery encodes an RFC 1035 query for name in family qtype. The
// ID comes from the kernel CSPRNG — a predictable ID is a spoofing
// invitation the clock-and-counter version of this file had to paper
// over. The query must fit ONE datagram — anything longer is refused,
// never truncated onto the wire. The reply must echo the ID AND the
// question section byte-for-byte; the caller passes query[12:] to the
// parse for that check.
func buildDNSQuery(name string, qtype uint16) ([]byte, uint16, error) {
	if name == "" {
		return nil, 0, ErrNameTooLong
	}
	qname := make([]byte, 0, len(name)+2)
	start := 0
	for i := 0; i <= len(name); i++ {
		if i == len(name) || name[i] == '.' {
			label := name[start:i]
			if len(label) == 0 || len(label) > 63 {
				return nil, 0, ErrNameTooLong
			}
			qname = append(qname, byte(len(label)))
			qname = append(qname, label...)
			start = i + 1
		}
	}
	qname = append(qname, 0)
	if 12+len(qname)+4 > udpFromPayloadMax {
		return nil, 0, ErrNameTooLong
	}

	var draw [2]byte
	if _, err := Random(draw[:]); err != nil {
		return nil, 0, err
	}
	id := uint16(draw[0])<<8 | uint16(draw[1])
	query := make([]byte, 0, 12+len(qname)+4)
	query = append(query, byte(id>>8), byte(id))
	query = append(query, 0x01, 0x00)                         // flags: RD (recursion desired)
	query = append(query, 0x00, 0x01)                         // QDCOUNT = 1
	query = append(query, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00) // AN/NS/AR = 0
	query = append(query, qname...)
	query = append(query, byte(qtype>>8), byte(qtype))
	query = append(query, 0x00, 0x01) // QCLASS = IN
	return query, id, nil
}

// parseDNSReply parses one received datagram in the slot-85 shape
// ([4-byte source IPv4][8-byte UDP header][DNS message]) and extracts
// the usable records of the asked family. errNotOurs marks a datagram
// that is not our reply — wrong source IP (a spoof arriving on our
// port), wrong source port, wrong ID, a question section that does not
// echo ours byte-for-byte, or a packet that is not a response — the
// caller counts it and keeps waiting. A genuine failure (rcode, TC,
// truncation inside the message, no usable record) is an error.
func parseDNSReply(dgram []byte, server [4]byte, id uint16, question []byte, qtype uint16) (res DNSResult, err error) {
	if len(dgram) < 4+8+12 {
		// Shorter than the prefix + UDP header + DNS header: not a DNS
		// reply at all.
		return res, errNotOurs
	}
	// The spoof checks the fixed-port path could not express: the
	// datagram must come from the server we asked, on the resolver port.
	if [4]byte{dgram[0], dgram[1], dgram[2], dgram[3]} != server {
		return res, errNotOurs
	}
	srcPort := uint16(dgram[4])<<8 | uint16(dgram[5])
	if srcPort != DNSPort {
		return res, errNotOurs
	}
	msg := dgram[12:]
	if uint16(msg[0])<<8|uint16(msg[1]) != id {
		return res, errNotOurs
	}
	flags := uint16(msg[2])<<8 | uint16(msg[3])
	if flags&0x8000 == 0 {
		return res, errNotOurs // QR = 0: a query, not a response
	}
	if flags&0x0200 != 0 {
		// TC = 1: the answer did not fit one datagram. There is no TCP
		// fallback on this path — refuse explicitly.
		return res, ErrDNSTruncated
	}
	switch rcode := int(flags & 0x000F); rcode {
	case 0:
	case 3:
		return res, ErrNameNotFound
	default:
		return res, ErrDNSFailed
	}

	qdcount := int(uint16(msg[4])<<8 | uint16(msg[5]))
	res.Answers = int(uint16(msg[6])<<8 | uint16(msg[7]))
	// The question section must echo ours byte-for-byte: one question,
	// same bytes. A reply that matches ID/address/port but mangles the
	// question is not ours.
	if qdcount != 1 || len(msg) < 12+len(question) || !bytes.Equal(msg[12:12+len(question)], question) {
		return res, errNotOurs
	}
	off := 12 + len(question)

	// Walk EVERY answer the header claims: a message whose answer
	// section runs past the bytes we actually received has lied about
	// its own section — refuse whole, never trust a record that happens
	// to sit inside the prefix.
	var minTTL uint32 = 0xFFFFFFFF
	for i := 0; i < res.Answers; i++ {
		if off, err = dnsSkipName(msg, off); err != nil {
			return res, err
		}
		if off+10 > len(msg) {
			return res, ErrDNSFailed // TYPE(2) CLASS(2) TTL(4) RDLENGTH(2)
		}
		rectype := uint16(msg[off])<<8 | uint16(msg[off+1])
		ttl := uint32(msg[off+4])<<24 | uint32(msg[off+5])<<16 | uint32(msg[off+6])<<8 | uint32(msg[off+7])
		rdlen := int(uint16(msg[off+8])<<8 | uint16(msg[off+9]))
		off += 10
		if off+rdlen > len(msg) {
			return res, ErrDNSFailed
		}
		var a DNSAddr
		usable := false
		switch {
		case rectype == DNSQueryA && qtype == DNSQueryA && rdlen == 4:
			a = DNSAddr{IPv4: [4]byte{msg[off], msg[off+1], msg[off+2], msg[off+3]}}
			usable = true
		case rectype == DNSQueryAAAA && qtype == DNSQueryAAAA && rdlen == 16:
			a = DNSAddr{V6: true}
			copy(a.IPv6[:], msg[off:off+16])
			usable = true
		}
		if usable {
			if len(res.Addrs) < dnsAddrsMax {
				res.Addrs = append(res.Addrs, a)
			}
			if ttl < minTTL {
				minTTL = ttl
			}
		}
		off += rdlen // a record of another family (e.g. CNAME): skip it
	}
	if len(res.Addrs) == 0 {
		// Answered, but nothing of the asked family — the NODATA case
		// an AAAA-only name produces for A, named per family.
		if qtype == DNSQueryAAAA {
			return res, ErrNoAAAARecord
		}
		return res, ErrNoARecord
	}
	res.TTLNs = dnsClampTTL(minTTL)
	return res, nil
}

// dnsSkipName walks one (possibly compressed) name: a compression pointer
// consumes two bytes, real labels walk to the zero terminator.
func dnsSkipName(msg []byte, off int) (int, error) {
	for {
		if off >= len(msg) {
			return off, ErrDNSFailed
		}
		b := int(msg[off])
		if b == 0 {
			return off + 1, nil
		}
		if b&0xC0 == 0xC0 {
			if off+2 > len(msg) {
				return off, ErrDNSFailed
			}
			return off + 2, nil
		}
		if b&0xC0 != 0 {
			return off, ErrDNSFailed // unsupported label kind
		}
		off += 1 + b
	}
}

// ---------------------------------------------------------------------------
// M99i (#2187): the bounded per-process TTL cache — 16 slots keyed on
// (name, server, qtype), TTL clamped to [5s, 1h], earliest-expiry evicted.
// Per-process by construction: it lives in the program's address space,
// no daemon and no kernel state. Positive answers only — negative caching
// beyond this table is the card's non-goal.
// ---------------------------------------------------------------------------

const (
	dnsCacheSlots = 16
	dnsAddrsMax   = 8
	// The TTL clamp: a server's 0-second answer still buys the floor, a
	// week-long answer expires in an hour.
	dnsTTLFloorNs = 5_000_000_000     // 5 s
	dnsTTLCapNs   = 3_600_000_000_000 // 1 h
)

type dnsCacheEntry struct {
	name    string
	server  [4]byte
	qtype   uint16
	addrs   [dnsAddrsMax]DNSAddr
	naddr   int
	answers int
	expiry  int64 // Nanos() deadline
	valid   bool
}

var dnsCache [dnsCacheSlots]dnsCacheEntry
var dnsCacheMu sync.Mutex

// dnsClampTTL bounds a record's TTL to the card's floor and ceiling.
func dnsClampTTL(sec uint32) int64 {
	ns := int64(sec) * 1_000_000_000
	if ns < dnsTTLFloorNs {
		return dnsTTLFloorNs
	}
	if ns > dnsTTLCapNs {
		return dnsTTLCapNs
	}
	return ns
}

// dnsCacheGet returns the cached result when an unexpired entry matches.
// The returned TTL is the REMAINING lifetime, and Cached is set so the
// caller (and the CLI's evidence line) can name the path taken.
func dnsCacheGet(name string, server [4]byte, qtype uint16) (DNSResult, bool) {
	now := Nanos()
	dnsCacheMu.Lock()
	defer dnsCacheMu.Unlock()
	for i := range dnsCache {
		e := &dnsCache[i]
		if !e.valid || e.name != name || e.server != server || e.qtype != qtype || now >= e.expiry {
			continue
		}
		return DNSResult{
			Addrs:   append([]DNSAddr(nil), e.addrs[:e.naddr]...),
			TTLNs:   e.expiry - now,
			Answers: e.answers,
			Cached:  true,
		}, true
	}
	return DNSResult{}, false
}

// dnsCachePut records a successful lookup. An existing entry for the key
// is refreshed in place; otherwise an invalid/expired slot is taken, and
// failing both the earliest-expiring entry is evicted — the bound is the
// table, never a timer sweep.
func dnsCachePut(name string, server [4]byte, qtype uint16, res DNSResult) {
	now := Nanos()
	dnsCacheMu.Lock()
	defer dnsCacheMu.Unlock()
	victim := -1
	for i := range dnsCache {
		e := &dnsCache[i]
		if e.valid && e.name == name && e.server == server && e.qtype == qtype {
			victim = i
			break
		}
	}
	if victim < 0 {
		for i := range dnsCache {
			if !dnsCache[i].valid || now >= dnsCache[i].expiry {
				victim = i
				break
			}
		}
	}
	if victim < 0 {
		victim = 0
		for i := range dnsCache {
			if dnsCache[i].expiry < dnsCache[victim].expiry {
				victim = i
			}
		}
	}
	e := &dnsCache[victim]
	e.name = name
	e.server = server
	e.qtype = qtype
	e.naddr = min(len(res.Addrs), dnsAddrsMax)
	copy(e.addrs[:], res.Addrs[:e.naddr])
	e.answers = res.Answers
	e.expiry = now + res.TTLNs
	e.valid = true
}
