# ADR 0057: IPv6 scope — SLAAC from RAs, NDP, ICMPv6 echo, bounded state everywhere

- Date: 2026-10-17
- Status: **Accepted** — shipped by the M117 arc (#2450, closed):
  transport over v6 is live (`kernel/src/tcp.zig:467`,
  `kernel/src/syscall.zig:121`, M117c); this ADR is the card (#2473),
  and the M117 arc implemented it in the filed order: M117b the v6
  datapath + hermetic responders + `live-net-v6`, M117c transport over
  v6, M117d the opt-in bridged/vmnet attachments, M117e the grant-word
  scope qualifiers, M117f acceptance. (Number 0057 is the next free at
  write time; M115b's card holds 0056.)
- Card: **#2473** (M117 index **#2450**) — card 1 of 6. This is the one
  doc for the arc (AGENTS.md: one doc per arc, not four).
- Related: ADR 0007 (syscall ABI — no new slots here; the additive rule
  covers the op-10 marshal change in D8), ADR 0012 (the userland network
  ABI this arc extends), ADR 0054 D9/D12 (the `net` grant word and the
  audit-first posture M117e inherits), ADR 0024 D5 (no EL0 path raises
  privilege — v6 opens ride the existing gated ops), M97e-F3 / issue
  #2102 (the solicited-only learning precedent D5 extends to NDP),
  `docs/hardware-contract.md` (the NAT's boot-time RA row).

> The guest is a NAT-only island that drops the one IPv6 packet it has
> ever been sent — the router's boot-time RA — in the MAC filter. M117
> makes it a citizen: **one new ethertype leaf on the existing demux
> seam, a bounded multicast accept set, a link-local derived from the
> device MAC, one SLAAC global from a bounded RA acceptance, NDP in
> `arp.zig`'s exact shape — 4 slots, one pending solicitation, learned
> only when solicited — and ICMPv6 echo in `ipv4.zig`'s.** Everything is
> hermetic-first: the runner gains request-driven `--net-ra-respond` /
> `--net-ndp-respond` / `--net-icmp6-respond` synthesizers in the
> capture thread, the same shape as `--net-arp-respond`. Bridged and
> vmnet attachments are opt-in flags that refuse by name when the
> interface or entitlement is absent. The guest is a host, not a
> router: no forwarding, no DHCPv6, no privacy rotation, no
> extension-header walk, no reassembly — ever.

## Mission

Pin, before M117b writes a parser: what IPv6 means here (the address
model, the bounded tables, the refusal names), the MAC-filter and demux
changes v6 needs, the RA/NDP/ICMPv6 acceptance rules, the hermetic
responder grammar, the bridged/vmnet posture and its named refusals,
the policy seam M117e extends, and the file-level Touches for M117b–f
so those cards land without renegotiation.

## Grounding (observed in tree `06ed0b6a` and on this host, 2026-10-17)

**[observed]** means checked in the tree, the Xcode 27 SDK headers, or
the live record; **[inferred]** means reasoning only.

1. **The v4 stack is one demux seam.** `virtio_net.zig`'s polled RX
   drain MAC-filters (`mac_accept`, own MAC + `ff:ff:ff:ff:ff:ff`
   broadcast only), pushes into a bounded 4-slot / 4096-byte FIFO
   (`fifo_slots`, `rx_buf_len`), and calls *both* `rx_arp` and
   `rx_ipv4` on every accepted frame — each layer self-filters on
   ethertype. TX is `build_frame` + the one-request-at-a-time
   `net_send` into fixed `tx_staging` behind a zeroed 12-byte
   `virtio_net_hdr`. Every drop carries a counter; every report line
   appends. **[observed]**
2. **ARP is the bounded-neighbor precedent.** `arp.zig`: `table_slots`
   = 4, round-robin drop-oldest, no expiry (documented, not assumed);
   `pending_reply` is ONE slot and a reply is learned only against it —
   an unsolicited reply can never create or overwrite an entry
   (M97e-F3, #2102 — an on-link host could otherwise overwrite the
   gateway mapping and redirect every off-subnet flow). Off-subnet
   sends resolve the *next hop* (`default_gateway`), never the literal
   peer. **[observed]**
3. **ipv4.zig's honest bounds.** IHL must be 5 (no options); a fragment
   (MF or nonzero offset) is dropped counted — no reassembly; protocol
   ≠ ICMP is dropped counted; ICMP is echo request/reply only. UDP
   computes its checksum always (the RFC 768 zero escape is never
   used). `dns.zig` is A-records only (`type_a` = 1, `rdlength` = 4).
   **[observed]**
4. **The socket table is numeric-v4 and bounded.** `socket_core.zig`:
   `Endpoint{ ip: [4]u8, port: u16 }`, 4 listeners + 4 connections +
   per-owner limit inside a 24 KiB budget; owner-keyed,
   generation-bearing handles. `vi.Dial` parses a dotted-quad literal
   or a DNS name and marshals the connect target as a 32-bit register
   word (`ipv4Word`). **[observed]**
5. **The hermetic net is a datagram socketpair.** `--net <file>`
   attaches `VZFileHandleNetworkDeviceAttachment` over one
   `SOCK_DGRAM` `socketpair(AF_UNIX)`: each guest TX frame is a
   datagram the capture thread reads and logs; each responder
   (`--net-arp-respond`, `--net-icmp-respond`, `--net-udp-respond`,
   `--net-dns-respond`, `--net-sntp-respond`, `--net-dhcp-respond`,
   `--net-tcp-respond`…) is a request-driven synthesizer in that same
   thread that writes its reply into the runner's end (VZ reads
   `fds[0]`, so the guest receives it). The hermetic host peer MAC is
   fixed at `02:00:00:00:00:02`; the guest's is `02:00:00:00:00:01`
   (`net: mac=… source=feature` — host-set via `VIRTIO_NET_F_MAC`).
   nil flag = unanswered = the default VM unchanged. **[observed]**
6. **The NAT attachment already speaks v6 at us.** The
   `VZNATNetworkDeviceAttachment` (`--net-nat`, mutually exclusive
   with `--net` — "one network device per guest for now") sends an
   IPv6 RA multicast at boot, and the MAC filter drops it —
   `docs/hardware-contract.md` records this as "not a regression".
   What the RA *carries* (prefix, flags, lifetime) is unobserved —
   the filter drops it before any layer parses it. **[observed]**
7. **Bridged and vmnet attachments ship in the SDK.**
   `VZBridgedNetworkDeviceAttachment.h` (Xcode 27 SDK) documents that
   the attachment "requires the app to have the
   `com.apple.vm.networking` entitlement";
   `VZVmnetNetworkDeviceAttachment.h` is `API_AVAILABLE(macos(26.0))`,
   backed by a `vmnet` logical network, and requires an entitlement
   the header does not name. `host/vm-runner/entitlements.plist`
   carries only `com.apple.security.virtualization`. **[observed]**
8. **The report and monitor surface.** `monitor.zig`'s `net` report is
   append-only `key=` lines (`net: ip=… arp=req=…`, ` icmp=…`,
   ` udp=…`, ` dhcp=…`); the shell exposes `net ip`, `net arp`,
   `net ping`, `net udp`, `net dhcp`, `net tcp`, `net dns`,
   `net recv`. `net: rx-armed` prints when the RX buffer is armed
   (`main.zig`). The lease timer precedent is the 1 Hz
   `timer.ticks` poll (`dhcp.zig` `now_ticks`). **[observed]**
9. **The grant table is landed.** `grant.zig` carries `(name, sha256,
   words)` rows over the nine `caps=` words; `word_net` is bit 7 and
   the slot-80 open-class ops (0 listen, 8 beginDns, 10 connect) are
   the `net` word's enforcement point (ADR 0054 D9). **[observed]**
10. **No v6 code exists.** `eth_type_ipv4` = 0x0800 is the only IP
    ethertype named; there is no `ipv6`/`ndp`/`icmp6` symbol anywhere
    in `kernel/src/`. **[observed]**

## Decision — Part I: the v6 datapath

### D1. One ethertype leaf on the existing seam

`eth_type_ipv6` = 0x86dd joins `eth_type_ipv4` and `ethertype_arp`.
The RX drain gains `rx_ipv6`, called on every accepted frame beside
`rx_arp`/`rx_ipv4`, self-filtering on ethertype — the demux pattern
unchanged. Two new pure-logic modules hold the protocol: `ipv6.zig`
(header parse/build, the address set, ICMPv6 echo, counters) and
`ndp.zig` (NS/NA/RS/RA, the neighbor table) — the fat.zig pattern:
no allocation, fixed BSS, host tests beside the code. TX rides
`build_frame` + `tx_staging` + `net_send` unchanged; a reply build
failure counts `reply_tx_fail` the same way. Nothing in the v4 path
is edited in meaning — a guest that never sees 0x86dd behaves
byte-identically.

### D2. The MAC filter gains a bounded multicast set

IPv6 does not broadcast; it multicasts. The filter grows from
{own, `ff:ff:ff:ff:ff:ff`} to a pure function of four accepts:

- own MAC, as today;
- broadcast, as today (v4 ARP/DHCP keep working);
- **all-nodes** `33:33:00:00:00:01` (ff02::1 — where RAs arrive;
  the observed boot RA's destination class);
- the **solicited-node** group `33:33:ff:xx:xx:xx` of every
  formed-or-tentative v6 address — the low 24 bits of the address.

The set is computed, never stored, and needs no
`VIRTIO_NET_F_CTRL_MAC` negotiation: the filter is guest-side
software over frames the device already delivers. Because D3 gives
every owned address the same IID, the solicited-node set is ONE
group — the whole accept set is four comparisons. Everything else
still drops into `rx_filtered`.

### D3. The address model: one IID, two addresses

The guest's interface identifier is the **modified EUI-64 of the
device MAC**: `mac[0] ^ 0x02` · `mac[1..3]` · `ff:fe` · `mac[3..6]`
(flip the universal/local bit). It is deterministic, gate-assertable
(the hermetic guest MAC 02:00:00:00:00:01 yields IID
`0000:00ff:fe00:0001`, link-local `fe80::ff:fe00:1`), and derived
from a property the host sets — the same observation channel as the
MAC itself.

The guest owns at most **two** v6 addresses:

- `fe80::/10` + IID — formed when the device MAC is known (feature
  negotiation), the always-present address;
- **one** SLAAC global — `prefix::IID` from the first accepted RA's
  first autonomous /64 PIO (D4).

No static-v6 setter exists in this arc; the monitor reports, it does
not assign. Source selection is by scope: NDP and link-local
destinations (fe80::/10) send from the link-local; everything else
sends from the global. A non-link-local destination with no global
formed refuses `no_src6` — an honest refusal, never a silent
link-local leak.

### D4. SLAAC: a bounded RS train and a bounded RA acceptance

When RX arms (`net: rx-armed`) the guest starts a **bounded Router
Solicitation train**: at most `rs_max` = 3 RSs (ICMPv6 type 133, src
link-local, dst all-routers ff02::2 / MAC 33:33:00:00:00:02), spaced
on the existing `timer.ticks` poll — the card-N9/dhcp retry
precedent, not a new timer facility. The train exists because the
observed boot RA can arrive before the filter admits it; an
unsolicited RA is processed identically whenever it lands.

An RA is **accepted** only when all of: ethertype 0x86dd,
next-header 58, hop_limit == 255 (the RFC 4861 §6.1.2 validity
check — cheap, pinned for every NDP/RA message in both directions),
valid ICMPv6 checksum, type 134, and a link-local source. The
options walk is bounded: at most `ra_opt_max` = 8 options, each
length-checked — a malformed length refuses the *whole* RA,
`ra_malformed` (never a partial trust). The first Prefix Information
option (type 3) with the **A** flag and prefix_len ≤ 64 forms the
global under D3 — a non-/64 A-flag prefix is counted `opt_skipped`,
never truncated into an address; the same option's **L** flag marks
the prefix on-link for D9. The RA source becomes the default router
iff router lifetime > 0: **one router record** — an RA from a
different source is `ra_foreign`, counted and ignored; a repeat RA
from the accepted source refreshes the record.

The M (managed) and O (other) flags, and the PIO valid/preferred
lifetimes, are **recorded into the report, never acted on** — no
DHCPv6 client exists (non-goal), and address/router expiry timers
are documented-not-implemented, the ARP no-expiry precedent. RDNSS
(type 25) and every unknown option are `opt_skipped`.

### D5. NDP is ARP's shape, translated

`ndp.zig` mirrors `arp.zig` exactly:

- **The neighbor table:** `ndp_slots` = 4 entries `{v6addr, mac,
  valid}`, round-robin drop-oldest, no expiry — no RFC 4861 NUD
  state machine (INCOMPLETE/REACHABLE/STALE/DELAY/PROBE are
  documented-not-implemented; the table bound and the pending slot
  are the whole state).
- **Learning is solicited-only:** `pending_na` is ONE slot, set by
  the NS we transmit; a Neighbor Advertisement is learned only when
  it carries S=1 and its target matches the pending solicitation —
  the M97e-F3 precedent. An unsolicited NA is `na_unsolicited`,
  counted and dropped: an on-link host cannot overwrite the router
  mapping.
- **Answering:** an NS (type 135) whose target is an owned address
  is answered with an NA (type 136, S=1 O=1, TLLA option = our MAC)
  sent to the NS frame's Ethernet source — replying to the observed
  src MAC, not a parsed option. An NS for any other target is
  `ndp_drop` counted.
- **Hop limit:** every NDP message and every accepted RA requires
  hop_limit == 255 inbound and sends it outbound — the standing
  off-link-forgery check.
- **Redirect (137):** counted `redirect_dropped`, never honored —
  the router record is RA-only (D4), and a forged Redirect is the
  classic on-link reroute.
- **DAD, one probe:** a formed address stays `tentative` until its
  one NS (src ::, dst the tentative solicited-node group — the
  RFC 4862 shape) goes unanswered for one bounded wait on the tick
  seam. A conflicting NA or an NS for the same target is
  `dad_conflict`: the address never leaves tentative and the guest
  keeps running — a named refusal, not a panic. One probe, not the
  full RFC retransmit schedule — the controlled links make deeper
  paranoia unobservable, and the conflict leg is gate-assertable
  (a responder answering our DAD NS proves the refusal).

### D6. ICMPv6: echo plus the NDP carry; everything else counted

`ipv6.zig` dispatches ICMPv6 (next-header 58) by type: **128** echo
request → byte-exact reply (`echo_replies_sent` — the `net ping6` /
GOSH `ping6` round trip); **129** echo reply → `pongs6_observed` +
the sequence, the ping proof; **133** RS → counted, dropped — the
guest is a host and never answers solicitations; **134/135/136** →
`ndp.zig` under D4/D5; **137** Redirect → `redirect_dropped`;
**types 1–4** (dest-unreachable, packet-too-big, time-exceeded,
param-problem) → counted `icmp6_err` and recorded, never acted on —
no PMTUD machinery exists and none is needed because every v6 send
is bounded to the 1280-byte minimum-MTU envelope; **all other types**
→ `dropped_type`. The ICMPv6 checksum over the v6 pseudo-header
(16-byte addrs, 32-bit length, next-header) is always verified
inbound and always computed outbound — v6 has no zero escape and
`udp.zig`'s always-compute posture stands.

### D7. Terminal next-headers only — no extension walk, no fragments

A v6 datagram is accepted when the fixed 40-byte header parses,
version == 6, `payload_len` covers the bytes present (a zero
`payload_len` jumbogram is `dropped_len`), hop_limit > 0, and
next-header ∈ {58 ICMPv6, 17 UDP, 6 TCP} — a terminal header,
directly. **No extension headers are walked**: hop-by-hop, routing,
fragment, destination-options, AH/ESP are all `dropped_nexthdr`,
counted. There is no reassembly — a fragment header never reaches a
transport. This is the v4 honest-bound shape restated: IHL==5,
MF-drop, counted.

## Decision — Part II: reach

### D8. Transport and ABI: a family tag, not a new surface

M117c puts UDP and TCP on v6 by parameterizing the existing code,
not cloning it:

- The UDP/TCP checksum pseudo-header gains a v6 form (16-byte
  addresses, 32-bit length, next-header) selected by the endpoint's
  family — the same builders, a second pseudo-header layout.
- `socket_core.Endpoint` widens to
  `{ family: enum { v4, v6 }, addr: [16]u8, port: u16 }` — v4
  occupies the low 4 bytes. **No v4-mapped v6 addresses on the
  wire**: the 16-byte field is storage, not a packet shape (a mapped
  literal is refused `bad_dst6`, not translated). Table bounds —
  4 listeners, 4 connections, per-owner limit — are unchanged; a v6
  socket costs the same slot.
- `vi.Dial` accepts a bracketed v6 literal. The 16-byte literal
  cannot ride a register word the way `ipv4Word` does, so the
  op-10 connect marshals it through the `uaccess.copy_in` seam — the
  ABI's existing >8-byte-argument channel — under a family tag on
  the **same** open-class op. No new slot: ADR 0007's additive rule
  is untouched, and ADR 0054's open-class enforcement covers v6
  dials identically.
- `ping6` lands in `user/go/ping` reachable from GOSH.
- DNS stays as it is: `dns.zig` is A-only and resolver transport is
  v4-only; a v6 destination is reached by literal. The runner's
  AAAA answer knob (`--net-dns-answer6`, M99i) is unaffected — the
  guest never asks.

### D9. Outbound dispatch: on-link or via the router

A v6 destination is **on-link** iff fe80::/10 or within the L-flag
PIO prefix D4 recorded; on-link sends NDP-resolve the destination
itself (the NS targets the destination's solicited-node group).
Off-link sends NDP-resolve the **router's link-local** and transmit
to the learned MAC — the ARP next-hop precedent: the wire asks for
the next hop, never the literal peer. Off-link with no router
refuses `no_route6`, counted. Destinations shaped multicast
(ff00::/8), unspecified (::), or loopback (::1) refuse `bad_dst6`
at send — the guest originates no multicast in this arc. The
v6-resolution wait rides the same pending-slot + tick-seam shape as
the ARP wait.

### D10. The hermetic responders — the gate surface

Three request-driven synthesizers join the capture thread in exactly
the `--net-arp-respond` shape: each inspects the guest's TX
datagram, writes a synthesized reply into `fds[1]`, prints a
`NET-*:` line; an unset flag means unanswered and the default VM is
unchanged. The hermetic host peer keeps its fixed MAC
`02:00:00:00:00:02`; its link-local is the EUI-64 derivation
`fe80::ff:fe00:2` — deterministic, gate-assertable.

- `--net-ra-respond <v6-prefix>` (e.g. `2001:db8:64::/64`): on a
  guest RS, write an RA — src the router link-local, dst all-nodes
  (the guest's D2 filter admits it), hop_limit 255, router lifetime
  > 0, one PIO carrying the argument prefix /64 with A+L and finite
  recorded lifetimes, checksums recomputed.
- `--net-ndp-respond <v6-addr>` (repeatable): on a guest NS whose
  target is a listed address, write the NA (S=1 O=1, TLLA =
  `02:00:00:00:00:02`). When `--net-ra-respond` is set, the router
  link-local is implicitly listed — the guest's router-resolution NS
  is answered without a second flag. An NS for an unlisted target
  goes unanswered: the refusal leg.
- `--net-icmp6-respond <v6-addr>`: on an echo request for the
  address, write the echo reply — the `--net-icmp-respond` mirror
  (id/seq/payload byte-exact, checksums recomputed).

`live-net-v6` chains them in the arp/icmp spec shape: RS → RA →
SLAAC global formed → NS/NA against the router → echo round trip,
byte-exact captures plus guest-observed counters — and a negative
leg (an NS nobody answers stays a counted pending, never a learned
entry).

### D11. Bridged and vmnet: opt-in attachments, named refusals

`--net-bridged <iface>` attaches `VZBridgedNetworkDeviceAttachment`
on the named `VZBridgedNetworkInterface`; `--net-vmnet` attaches
`VZVmnetNetworkDeviceAttachment` on a vmnet logical network (macOS
26+ — Grounding 7). The posture is the index's second thesis:

- **Off by default.** No flag, no attachment — the VM config is
  byte-identical. Both stay mutually exclusive with `--net` and
  `--net-nat`: the one-network-device bound stands.
- **Every failure is a named refusal**, asserted as loudly as the
  success path: the entitlement absent → the runner `fail()`s naming
  it; the named interface absent from
  `VZBridgedNetworkInterface.networkInterfaces` → `fail()` naming the
  interface; a non-success `vmnet_return_t` → `fail()` carrying the
  status. `entitlements.plist` gains the entitlement M117d's probe
  names (Grounding 7 leaves the vmnet key itself an open question).
- **The guest stack does not change.** Bridged/vmnet is a different
  attachment behind the same virtio-net device: DHCP v4, SLAAC v6,
  and every bound above run unchanged — which is exactly what makes
  the acceptance leg honest.

### D12. Policy: the `net` word already covers v6

v6 opens ride the same slot-80 open-class ops, so the word
vocabulary is **unchanged** — no new word, no new slot group; a
process with `net` can open v6, a process without it cannot
(ADR 0054 D9 stands verbatim). What M117e adds is *scope inside the
row*: the grant row gains optional qualifiers — a v6 prefix literal
and an interface name — evaluated at the open-class op, so
off-policy v6 literals and bridged destinations refuse by name.
Qualifier tokens and refusal names are M117e's deliverable; the
audit-first posture (ADR 0054 D12) carries over unchanged.

### D13. Observability: appended counters, same report

The `net` report appends v6 lines under the standing append-only
convention — existing substring asserts stay green. The new counters
name every bound above: RA accepted/foreign/malformed, RS sent,
NS/NA sent, learned, dropped, TX-failed, DAD conflicts, echo
req/repl/pong, per-drop-cause; the formed addresses and the router
record print beside them (`net: v6=…`, `ndp=…`, `icmp6=…` — exact
tokens are the implementing card's, the discipline is the decision).
`net recv` keeps printing raw frames, v6 included — the observation
seam is unchanged. Monitor additions are report-level: `net ip6`
shows the address set, `net ndp` the table; a v6 *setter* exists
only as `ping6`-style traffic drivers, matching the v4 shape.

## Non-goals (explicit)

| Non-goal | Where it stands |
|---|---|
| DHCPv6 — stateful *and* stateless | The RA M/O flags are recorded, never acted on; RDNSS options are `opt_skipped`. Guest DNS stays v4/A-only |
| Mobile IPv6, home agents, binding updates | Never — the guest is a fixed host |
| Privacy extensions beyond the stable IID | RFC 4941 temporary/rotating addresses are out; the EUI-64 IID is THE IID, deterministic and gate-assertable |
| Forwarding / routing | The guest is a host: a packet not for us is filtered or `ndp_drop`, never re-sent; an RS is never answered |
| Extension headers, fragmentation, reassembly | `dropped_nexthdr`, counted — D7 |
| PMTUD | packet-too-big is `icmp6_err`, recorded only; sends stay inside the 1280 envelope |
| MLD reports | Membership is filter-local; no ICMPv6-143 on the wire (controlled links; Open issues for the bridged corner) |
| AAAA records / v6 resolver transport | Literal-only v6 dialing — `dns.zig` unchanged |
| A second network device | `--net`/`--net-nat`/`--net-bridged`/`--net-vmnet` are mutually exclusive; the one-device bound stands |
| Changing the default attachment | The default VM has no network device at all; nothing here is default-on |

## Card split — file-level Touches

Lanes are `a → b → c → {d ∥ e} → f` (the index). Touches below are the
honest file sets this ADR's decisions imply; where a filed claim's
`--touches` under-lists (noted), the claiming agent amends its claim
comment — one editor per file is what the gate checks, and the lanes
keep these sets serial anyway.

| Card | Issue | Delivers | Touches |
|------|-------|----------|---------|
| M117b | #2474 | `ipv6.zig` + `ndp.zig`, the D2 filter, `rx_ipv6` demux, RS train + DAD, the three responders, `live-net-v6` | `kernel/src/ipv6.zig`, `kernel/src/ndp.zig`, `kernel/src/virtio_net.zig`, `kernel/src/main.zig`, `kernel/src/monitor.zig`, `kernel/src/shell.zig`, `host/vm-runner/Sources/VMRunner/main.swift`, `tools/gate/specs/live-net-v6.spec`, `docs/hardware-contract.md` (the NAT row's "dropped by the MAC filter" clause) — the filed claim's `kernel/src/net*.zig` under-lists; amend at claim |
| M117c | #2475 | v6 pseudo-header + demux in UDP/TCP, `Endpoint` family tag, `vi.Dial` v6 literal, `ping6`, `go-net` v6 legs | `kernel/src/udp.zig`, `kernel/src/tcp.zig`, `kernel/src/socket_core.zig`, `kernel/src/socket_native.zig`, `kernel/src/syscall.zig` (the op-10 marshal), `user/go/vi/*`, `user/go/ping/*`, `tools/gate/specs/go-net.spec` — the filed claim under-lists the socket files; amend at claim |
| M117d | #2476 | `--net-bridged` + `--net-vmnet`, entitlement, named refusals, `live-net-bridged` | `host/vm-runner/Sources/VMRunner/`, `host/vm-runner/entitlements.plist`, `tools/gate/specs/live-net-bridged.spec` |
| M117e | #2477 | `net` row scope qualifiers: v6 prefix + interface matching, refusal legs | `kernel/src/grant.zig`, `kernel/src/socket_core.zig`, `kernel/src/socket_native.zig`, `tools/gate/specs/` |
| M117f | #2478 | `live-web` v6 leg, `live-net-bridged` LAN-httpd leg K=3, status row, index closure | `tools/gate/specs/live-web.spec`, `tools/gate/specs/live-net-bridged.spec`, `docs/status.md` |

## Consequences

- A boot that sees no 0x86dd frame is byte-identical to today — the
  whole arc is additive behind one ethertype and a computed accept
  set.
- The first v6 packet the guest has ever been sent — the NAT's
  boot-time RA — stops being a filtered drop and becomes the SLAAC
  trigger on `--net-nat`; on the hermetic net the RS train makes the
  same exchange deterministic. (Whether the NAT's RA carries a usable
  prefix is an open issue, not an assumption.)
- The solicited-only learning rule extends the M97e-F3 forgery fix to
  v6 by construction: no unsolicited NA or Redirect can move a
  neighbor or router mapping.
- Every bound is a counter before it is a promise — the v6 report
  lines make the drops observable in the same format every existing
  gate already greps.
- Bridged reachability costs exactly one entitlement entry and one
  flag; when either is absent the refusal names the missing piece.

## Rejected alternatives

- **DHCPv6 (stateful or stateless).** A second lease machinery for a
  protocol nothing observed sends usefully — RA is what the platform
  emits (Grounding 6); DNS stays on the v4 resolver. The M/O flags
  are recorded so the report shows what was offered and ignored.
- **Full RFC 4861 NUD timers.** The ARP precedent is no-expiry; a
  five-state reachability machine adds timers and probe logic for no
  observed need — the table bound plus the pending slot is the whole
  honest state.
- **RFC 7217 opaque or RFC 4941 rotating IIDs.** EUI-64 is
  deterministic, gate-assertable, and derived from a host-set
  property; rotation is the index's named non-goal.
- **Learning unsolicited NAs.** M97e-F3 observed the forgery it
  enables; solicited-only stands (D5).
- **An extension-header walk.** Complexity for traffic nothing here
  produces; terminal-only matches the IHL==5 / MF-drop posture.
- **A parallel v6 socket table or a new slot.** One field's width is
  not a new ABI — the family tag rides the existing open-class op
  (D8), and the additive rule stays clean.
- **Honoring Redirects.** The router record is RA-only; Redirect is
  the classic on-link reroute primitive.
- **Treating the NAT RA's contents as known.** Unobserved — the
  filter drops it today. The hermetic responders own the gate proof;
  the NAT leg is a probe, not an assumption.

## Open issues

- **What the NAT's RA carries.** Observed only as "IPv6 RA multicast
  at boot, dropped by the MAC filter". Whether it offers an A-flag
  /64 the guest can SLAAC — and whether NAT'd v6 egress works at
  all — is a `--net-nat` leg for M117b to record into the hardware
  contract. If the NAT offers no usable prefix, NAT-boot v6 is
  link-local-only and every bound above still stands.
- **The vmnet entitlement name.** The bridged header names
  `com.apple.vm.networking`; the vmnet header requires "an
  entitlement" without naming it (`com.apple.vm.networking` vs
  `com.apple.developer.networking.vmnet` are the candidates).
  M117d's probe names it; either way the refusal path is the same.
- **MLD on real LANs.** We send no MLD reports; if a bridged LAN
  switch prunes multicast to unregistered ports, solicited-node and
  all-nodes delivery could starve. The `live-net-bridged` leg is the
  observation; the named fallback is bounded MLD v1 reporting
  (ICMPv6 type 143) as a later amendment.
- **DNS over v6 / AAAA.** Literal-only dialing is scoped; if a real
  need shows up, extending `dns.zig` is a later card against this
  ADR's D8 marshalling seam.
