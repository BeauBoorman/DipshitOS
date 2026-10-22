---
title: Networking
parent: capabilities
status: published
tags: [capabilities, networking]
---

# Networking

The network stack is a from-scratch, RFC-shaped protocol tower over the
virtio-net transport — ARP, IPv4, ICMP, UDP, DHCP, TCP, DNS, TLS 1.3,
HTTP/1.1, SNTP, and a bounded IPv6 stack — all in fixed BSS with named
drops for everything the stack chooses not to be. It is a host, not a
router, and every bound is a refusal with a name rather than a silent
edge.

## The transport

`--net` attaches a `VZVirtioNetworkDeviceConfiguration` — a modern
virtio-net device (`0x1af4:0x1041`, queues 0=RX / 1=TX). The negotiated
feature mask is `VERSION_1 | MTU | MAC`; a VER1-only offer is rejected
by the device, and the host-set MAC comes from device config under
`VIRTIO_NET_F_MAC`, which is how gates assert on it. Every buffer
carries a 12-byte `virtio_net_hdr`: zeroed on TX, written into RX.

RX buffers are polled — the used-buffer IRQ is unobserved — and frames
below ~1530 B wedge the device, so the pool arms 4 KiB buffers. Accepted
frames pass a MAC filter (own + broadcast + the IPv6 multicast groups
below), land in a bounded 4-slot FIFO, and each protocol layer
self-filters on ethertype: `0x0806` → ARP, `0x0800` → IPv4,
`0x86dd` → IPv6. Sub-60-byte frames travel unpadded both directions.

## IPv4 and friends

| Layer | Module | Shape |
|-------|--------|-------|
| ARP | `arp.zig` | RFC 826; a 4-slot table, one pending solicitation; a reply is learned **only against the pending slot** — unsolicited answers can never overwrite the gateway mapping. Off-subnet sends resolve the next hop, never the literal peer. |
| IPv4/ICMP | `ipv4.zig` | RFC 791/792; IHL=5 enforced, fragments dropped and counted (no reassembly); echo request answered, `net ping` originates. |
| UDP | `udp.zig` | RFC 768; pseudo-header checksum always computed (the zero escape is never used); bounded listen table; own-IP sends loop back without touching the device. |
| DHCP | `dhcp.zig` | RFC 2131 client: DISCOVER → OFFER → REQUEST → ACK, then renew / rebind / expire on the lease timer. |
| DNS | `dns.zig` | RFC 1035 client: A records only, one query at a time, no cache — `net dns <name>` and the Go resolver share it. |

## TCP

`tcp.zig` implements the wire; `socket_core.zig` (behind syscall slot
80) is the owner-approved socket table the live system runs on: **4
listeners + 4 connections, ≤4 sockets per owner, ≤2 accepted children
per listener, inside a 24 KiB budget**, with generation-tagged handles
(`gen:48 | slot`). The lifecycle is the full RFC 793 shape — SYN →
SYN-ACK → data → FIN → FIN-ACK → final ACK — with a bounded out-of-order
reassembly window per connection (1460 B + a validity bitmap) and an
advertised window that tracks real free space (the SYN's 4096 is honest
only while the queue is empty).

Retransmission is **adaptive, RFC 6298**: each connection runs an
SRTT/RTTVAR estimator with a 200 ms floor, a 60 s ceiling, Karn's rule,
and exponential backoff, capped at 10 retransmissions before an honest
abort (`retx_aborted`). A separate 30 s connect deadline covers the
half-open case. Peer MSS is honored as an outbound clamp (we advertise
1460); options are parsed and skipped, with malformed lists dropped in
their own counter — no window scaling, SACK, timestamps, congestion
control, or keepalive. An over-cap SYN — a second peer knocking while
the slot is taken — is refused with RST+ACK in its own bounded slot,
never silently dropped, and a peer RST on a never-accepted child frees
the slot immediately rather than charging a zombie.

The legacy monitor client (slots 30–33) remains a deliberate singleton
on fixed source port 8000; production traffic — `AGENTD.ELF`, the SSH
server, `GOHTTPD.ELF`, the RFB seat — rides the slot-80 table. The
listen depth is named: `listener_limit`, `conn_limit`, `owner_limit`,
`child_limit` all refuse by name (`owner_saturated`, `child_limit`
→ `ENOSPC`), which the M135 listen-depth legs pin end to end.

## IPv6

ADR 0057's bounded v6 stack is a leaf on the same demux seam — one
`0x86dd` dispatch beside ARP/IPv4, in `ipv6.zig` + `ndp.zig`:

- **Address model.** One IID — the modified EUI-64 of the device MAC —
  shared by at most two owned addresses: the link-local `fe80::/10`
  (always present) and **one** SLAAC global from the first accepted
  RA's first autonomous-/64 PIO.
- **SLAAC.** A bounded Router Solicitation train (≤3 RSs, hop-limit
  255); an RA is accepted only with hop_limit 255, a valid checksum,
  and a link-local source — its first A-flag PIO forms the global and
  its source becomes the one router record. Foreign RAs, malformed
  option lengths, and Redirects are counted, never trusted.
- **NDP** is ARP's shape translated: a 4-slot neighbor table, one
  pending solicitation, solicited-only learning (an unsolicited NA is
  `na_unsolicited`), hop-limit 255 in both directions, and a one-probe
  DAD — a conflict is `dad_conflict`, a named refusal, not a panic.
- **ICMPv6** carries echo (request answered byte-exact, `ping6`
  originates) plus the NDP types; errors 1–4 are recorded, never acted
  on — every v6 send already fits the 1280-byte minimum MTU.
- **Transports.** UDP and TCP ride v6 through a family-tagged
  `Endpoint` — a v6 socket costs the same slot. `vi.Dial` accepts a
  bracketed `[addr]` literal; the 16-byte target marshals through the
  ABI's `uaccess.copy_in` seam on the same open op, no new slot. DNS
  stays A-over-v4, so a v6 destination is reached by literal.

MAC filtering admits `33:33:00:00:00:01` (all-nodes, where RAs land) and
the solicited-node group of each formed address — a four-comparison
computed set, no multicast state. `live-net-v6` and the `--net-ra-respond`
/`--net-ndp-respond` / `--net-icmp6-respond` / `--net-tcp6-respond` /
`--net-udp6-respond` hermetic responders pin it end to end.

## TLS 1.3

Both directions exist, in-tree, with no third-party TLS or X.509 code.
The client (ADR 0029) is `user/src/lib/tls` plus the Go `user/go/tls`
port: HKDF/SHA-384 key schedule, `TLS_AES_128_GCM_SHA256` with x25519,
AES-GCM record protection, a named handshake state machine
(application data reachable only from `connected`), and X.509 chain
validation against a caller-owned, capacity-bounded trust store —
RSA-PKCS1/PSS and ECDSA P-256/P-384 verification included. It fails
closed everywhere: self-issued certs can't anchor themselves, unknown
critical extensions fail the chain, and the named negatives — name
mismatch, expired, broken chain — are pinned by `go-fetch-https`. Real
interop ran against four peer implementations and eight public
endpoints.

The server half (the M135 net-depth arc) puts the same library behind
`GOHTTPD.ELF`, so the in-guest web server serves real HTTPS — the
acceptance is an HTTPS serve plus a keep-alive fetch plus named
saturation, K=3. No PSK, no 0-RTT, no client certs, no OCSP/CRL —
scope is the mandatory suite, and HelloRetryRequest is rejected
explicitly rather than mishandled.

## HTTP/1.1

`user/go/httpc` is the shared client wire engine for `GOFETCH.ELF` and
`WEB.ELF`: keep-alive armed, gzip accepted, an incremental chunked
decoder, and a named refusal grammar (`http-framing-invalid`,
`http-header-limit`, `http-body-limit`, `http-premature-eof`,
`chunked-malformed`, `gzip-*`) that cannot diverge between consumers.
`GOHTTPD.ELF` serves persistent HTTP/1.1 — request-head bound at 1 KiB,
canonical-path resolution under `/host`, version-correct keep-alive
semantics — and answers on the slot-80 listener. `live-httpd` and
`go-fetch-https` gate both halves.

## Time over the wire

`time sync [SERVER]` in GOSH is an SNTP client over the UDP seam
(`virelai/timesync`): one query, a 5 s budget, Kiss-o'-Death / origin /
stratum / era sanity checks, a ±1 s deadband, and a step through
syscall slot 78 `sys_time_set` — range-clamped 2025–2100, and it works
on a boot with no firmware epoch. No reply, an offline link, or a bad
answer exits with the clock untouched. The runner synthesizes the
server side with `--net-sntp-respond <ip>` / `--net-sntp-skew <s>`.

## Transports: hermetic, NAT, bridged

| Flag | Attachment | What it is |
|------|-----------|------------|
| `--net <file>` | `VZFileHandleNetworkDeviceAttachment` | Hermetic: a `SOCK_DGRAM` socketpair the runner's capture thread logs, plus the `--net-*-respond` synthesizers that answer ARP/ICMP/UDP/DNS/DHCP/TCP/SNTP/RA/NDP on demand. Guest and host MACs are fixed (`02:00:00:00:00:01`/`…:02`); every gate's byte-exact evidence comes from here. |
| `--net-nat` | `VZNATNetworkDeviceAttachment` | Real NAT — the guest pings the gateway (observed `192.168.64.0/24`, gw `.1`, MAC varies per boot). Serves no DHCP (static fallback still reaches the gateway); a closed TCP port answers RST; it sends a boot-time IPv6 RA the stack now accepts. Evidence is guest-side counters — the host translates the frames, which is the point. |
| `--net-bridged <iface>` | `VZBridgedNetworkDeviceAttachment` | A real LAN leg — the guest DHCP-binds and reads a real httpd on en0 (`live-net-bridged`). Requires the restricted `com.apple.vm.networking` entitlement. |
| `--net-vmnet` | `VZVmnetNetworkDeviceAttachment` | A vmnet logical network (macOS 26+); requires `com.apple.developer.networking.vmnet`. |

The bridged/vmnet entitlements are **restricted**: an ad-hoc-signed
binary carrying either is killed by `amfid` before `main()` — observed,
not guessed — so they live in a sibling `entitlements-net.plist` for
development-signed builds while `entitlements.plist` stays the
ad-hoc-safe set every gate uses. Both flags are mutually exclusive with
`--net`/`--net-nat` (one network device per guest), absent → named
refusal, interface missing → named refusal. On the runner side the TCP
relay deduplicates retransmits and paces by the guest's advertised
MSS/window, which is what the in-guest `flint push` lane rides.

## Named limits

- **TCP:** bounded everything — the socket table's 4+4/owner/child caps,
  no congestion control, no keepalive, no window scaling/SACK/timestamps,
  fragments always dropped, the legacy client singleton on port 8000.
- **IPv4:** IHL=5 only; no options, no reassembly.
- **IPv6:** no extension-header walk, no DHCPv6, no forwarding, no
  privacy rotation, no multicast origination, NDP without the full NUD
  state machine (one probe, no retransmit schedule).
- **DNS:** A records, one query, no cache, v4-only transport.
- **Routing:** next-hop-only — the learned gateway is the whole
  off-subnet channel; there is no routing table beyond it.
- **TLS:** the mandatory suite only; revocation (OCSP/CRL) is a
  separate, unfixed question.

<Aside kind="info">

**VERIFIED.** Each layer has a class-B gate with byte-exact host
captures on the hermetic wire: `live-net-tx`, `-rx`, `-arp`, `-icmp`,
`-udp`, `-udp-syscall`, `-dhcp`, `-dhcp-renew`, `-tcp`, `-tcp-rto`,
`-nat`, `-v6`, `-bridged`, plus `live-httpd`, `live-rfb`, and the
`go-net-clis`/`go-fetch-https` app legs. Under NAT the evidence is
guest-observed counters — the host translates the frames.
</Aside>

<Aside kind="warning">

**LIMITATION.** This is a bounded protocol tower, not a general-purpose
stack: one passive-listener table with named saturation, a
single-connection legacy client, no routing beyond the gateway, no
DHCPv6, no fragment reassembly, no multicast origination. The bounds
are the point — every one is a named refusal, a counter, and a gate.
</Aside>
