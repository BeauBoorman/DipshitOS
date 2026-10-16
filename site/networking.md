---
title: Networking
parent: capabilities
status: published
tags: [capabilities, networking]
---

# Networking

The network stack is a from-scratch, RFC-shaped protocol tower over the
virtio-net transport, built in bounded fixed-BSS staging.

## The tower

| Layer | Implementation | Notes |
|-------|----------------|-------|
| Transport | `virtio_net.zig` | DID 0x1041; queues 0/1; 12-byte `virtio_net_hdr` on every buffer |
| ARP | `arp.zig` | RFC 826; static IP; bounded 4-slot table; answer + learn |
| IPv4 / ICMP | `ipv4.zig` | RFC 791/792; RFC 1071 checksums; echo answer + ping; fragments dropped (counted) |
| UDP | `udp.zig` | RFC 768; pseudo-header checksum always computed; bounded listen table; loopback |
| DHCP | `dhcp.zig` | RFC 2131 client: DISCOVER → OFFER → REQUEST → ACK, plus renew/rebind/expiry |
| DNS | `dns.zig` | RFC 1035 client: A-record queries over UDP, parse + extract, `net dns <hostname>` |
| TCP | `tcp.zig` | RFC 793: client (handshake, one in-flight segment, bounded retransmission) + passive-open server |
| TCP seam | `syscall.zig` TCP slots | `sys_tcp_connect`/`sys_tcp_send`/`sys_tcp_recv`/`sys_tcp_close` for EL0 |
| Sockets | `socket_core` + slot 80 | B6 #1873: native generation-tagged handles — one passive listener with up to two simultaneous children; `AGENTD.ELF` and the SSH server run on it |
| HTTPD | `user/go/httpd` (`GOHTTPD.ELF`) | Go HTTP/1.1 web server over the passive-open listener (gate `live-httpd`; Zig `user/src/httpd.zig` retired in M71l) |

## What works end to end

- **Raw Ethernet** — `netsend` transmits known frames the host captures
  byte-exactly; `net recv` prints received frames (MAC-filtered).
- **ARP** — the guest answers requests for its IP and resolves peers.
- **ICMP** — the guest answers echo requests and pings peers.
- **UDP** — loopback (own-IP sends never touch the device), datagrams to/from
  peers, and the EL0 syscall seam (`sys_udp_listen/send/recv`).
- **DHCP** — a bounded client that binds a lease, then renews, rebinds, and
  expires it on the lease timer.
- **TCP** — a bounded client (connect, send, receive, close, plus fixed-RTO
  retransmission with an abort bound) **and a passive-open server**, exposed
  to EL0 through the syscall seam (`TCP.BIN` proves the client;
  `GOHTTPD.ELF` proves the server).
- **DNS** — a bounded RFC 1035 resolver (`net dns <hostname>`) that queries
  port 53 and extracts A records, live-gated against a deterministic
  `--net-dns-respond` answer; the Go `GODNS.ELF` also resolves A records over
  the existing guest UDP syscall.
- **NAT** — the launcher's `--net-nat` mode attaches a real
  `VZNATNetworkDeviceAttachment`; the guest pings the NAT gateway.
- **HTTP server** — `GOHTTPD.ELF` accepts a connection on the passive-open
  listener and serves HTTP/1.1 over it; Zig `HTTPD.BIN` was retired to Go
  in M71l (gate `live-httpd`).
- **Userland network apps** — `TCP.BIN` (echo client), `GOFETCH.ELF` (HTTP
  client, successor to retired `FETCH.BIN`), `GOPING.ELF` (Zig `PING.BIN`
  retired in M71n), `GONETSTAT.ELF` (the slot-62 network dashboard),
  `GODNS.ELF` (UDP A-record lookup), and `GOTRACEROUTE.ELF` (bounded direct-peer
  ICMP echo diagnostic) run the seam end to end. The Zig graphical chat demo
  (`CHAT.BIN`) was retired in M78c; the UDP seam remains live-tested. The Go
  diagnostics replace their Zig `.BIN` originals and are built with
  `bash tools/go/build-netdiag.sh` before their live gates.

<Aside kind="info">

**VERIFIED.** Each layer has a class B gate with byte-exact host captures
where the attachment is deterministic (`live-net-tx`, `-rx`, `-arp`, `-icmp`, `-udp`, `-udp-syscall`, `-dhcp`, `-dhcp-renew`, `-tcp`, `-tcp-rto`,
`-nat`). Under NAT the evidence is guest-observed counters, because the host
translates the frames — that is the point of NAT.

</Aside>

## Honest bounds

- `GOTRACEROUTE.ELF` is a peer reachability probe, not route discovery: the
  current ICMP syscall has neither TTL selection nor time-exceeded responses.
  Its `-m` option bounds attempts; it does not set a packet TTL.
- TCP is **bounded**: the legacy slots 30–33 seam is a singleton client,
  while the slot-80 native socket family allows one passive listener with at
  most two simultaneous children system-wide; no TCP loopback, no congestion
  control, fixed window 4096, payload ≤ 64 bytes in one segment.
- RTO is fixed (3 ticks) with no Karn/exponential backoff; 10 retransmissions
  then an honest abort.
- DHCP has no hostname/DNS options and no relay; the lease is enforced but the
  client is not a full DHCP implementation.
- DNS is bounded: A records only, one query at a time, no caching, no other
  record types.
- No routing beyond the NAT gateway; no IPv6 stack.

<Aside kind="warning">

**LIMITATION.** No routing beyond the NAT gateway and no IPv6. TCP is a
singleton client plus one bounded passive listener (two children), not a
general-purpose network stack — the tower proves the protocol shapes and the
syscall seam.

</Aside>
