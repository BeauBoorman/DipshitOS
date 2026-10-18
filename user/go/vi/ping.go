package vi

// M71n (issue #1573): the Go binding for the M26 N1 ICMP syscall seam —
// slots 59 `sys_ping_send` and 60 `sys_ping_poll`.
//
// The kernel owns the semantics (kernel/src/syscall.zig handle_ping_send /
// handle_ping_poll); this file only marshals the argument word. It is the
// exact shape Zig's `ui.ping_send` / `ui.ping_poll` have, so GOPING.ELF
// speaks the same ICMP path the monitor's `net ping` does, and PING.BIN (the
// Zig predecessor this card retires) did.
//
// Off the guest the calls are -ENOSYS through the syscallHook seam, so the
// marshalling is host-testable without a NIC.

// PingSend sends one ICMP echo request to ip (dotted-quad order). The kernel
// resolves through ARP and refuses with EINVAL when there is no own IP, the
// peer is not in the ARP table, or the transport is not ready — the caller
// is expected to have run its offline/no-route preflight first.
func PingSend(ip [4]byte) error {
	word := uintptr(uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3]))
	r := svc1(SlotPingSend, word)
	if r < 0 {
		return errno(-r)
	}
	return nil
}

// PingPoll drains RX and returns the last echo-reply sequence seen, or 0 when
// no reply has landed yet. 0 is a "nothing yet", not an error: the caller
// sends, then polls until the expected sequence appears.
func PingPoll() uint64 {
	r := svc0(SlotPingPoll)
	if r < 0 {
		return 0
	}
	return uint64(r)
}

// ---------------------------------------------------------------------------
// M117c (#2475, ADR 0057 D10): the ICMPv6 half — same slots, tagged marshal
// ---------------------------------------------------------------------------

// familyV6Tag is kernel/src/syscall.zig `family_v6_tag`
// (0x0000_86dd_0000_0006): placed where the v4 form carries the IPv4
// word, it selects the v6 marshal — the 16-byte literal then arrives
// through the pointer argument (the kernel's uaccess.copy_in seam), and
// slots 59/60 answer the ICMPv6 counters (ipv6.pongs_observed/last_seq).
const familyV6Tag = 0x000086dd00000006

// Ping6Send sends one ICMPv6 echo request to a v6 literal (the wire-order
// 16 bytes from ParseIPv6). The kernel picks the source (select_src), the
// next hop (on-link or the recorded router) and refuses honestly — EINVAL —
// when no source is valid, no route exists, or the next hop is not in the
// NDP table (the caller should `net ndp <v6-addr>` first, same as v4 ARP).
func Ping6Send(addr [16]byte) error {
	r := svc2(SlotPingSend, familyV6Tag, bytePtr(addr[:]))
	if r < 0 {
		return errno(-r)
	}
	return nil
}

// Ping6Poll drains RX and returns the last ICMPv6 echo-reply sequence, or
// 0 when none has landed — the PingPoll contract on the v6 counters.
func Ping6Poll() uint64 {
	r := svc1(SlotPingPoll, familyV6Tag)
	if r < 0 {
		return 0
	}
	return uint64(r)
}
