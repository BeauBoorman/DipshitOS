> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone twenty-six march — network experience (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M26's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

The network stack (M5) has ARP, IPv4, ICMP, UDP, TCP, DHCP, DNS, NAT,
and a TCP retransmission timer. FETCH.BIN and CHAT.BIN (M12) prove the
TCP client works. But there's no way to *diagnose* the network from the
shell — no ping, no connection listing, no bandwidth display. M26 makes
the network *visible* and *useful*.

**One new syscall slot (62)** — `sys_net_stats`, the network dashboard's
read-only snapshot seam (the tracker's "reads via the serial monitor
interface" premise predated the syscall era; N2/N3 land claim 7635). All
other cards use existing network and process syscalls.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| N1 | **PING.BIN.** `ping 10.0.0.1` — sends ICMP echo requests, displays round-trip time, packet loss stats, and continuous mode (`ping -c 5 10.0.0.1`). Reports: packets sent/received/lost, min/avg/max RTT. Uses existing ICMP syscall seam (the kernel's `net ping` command reuses the same code path). | ✅ | claim 0640: `user/src/ping.zig` embedded in FAT32 image; `verify-live-n1-ping.sh` PASS on VZ (2026-08-25) | New userland app `user/src/ping.zig`. Sends ICMP echo requests via `ui.yield_task` polling and 1s cadence. Wired to FAT32 disk image (`image/mkfat32.py`, `image/make-image.sh`, `build.zig`). Live gate verifies 3 pings, 0% loss, RTT stats. |
| N2 | **NETSTAT.BIN.** `netstat` — shows a dashboard of: active TCP connections (TCP, peer, port), UDP listeners (port), ARP table (IP → MAC), DHCP state (ip/mask/gw/server/lease), network interface info (IP, MAC, gateway). Updates at 1 Hz. | ✅ | claim 7635: `sys_net_stats` (slot 62) + window app; `verify-live-netstat.sh` PASS 1/1 boots (2026-08-24) | New userland app `user/src/netstat.zig` (SEGMENTED DSK3, GLOBALS pattern) + `user/src/lib/netstats.zig` (mirror + `read_stats`). `sys_net_stats(buf, len)` copies the kernel's existing pub network globals (virtio_net net_mac/net_dev/rx_*, arp.own_ip/table, tcp state+peer+counters, udp.listen+counter, dhcp state+lease) as a fixed packed snapshot through uaccess (process-snapshot pattern). 1 Hz refresh via EVENT_TIMER. |
| N3 | **HTTP fetch display.** `fetch http://site/path` — extends FETCH.BIN with a terminal output mode. When run from the shell (not from the desktop), displays the response body in the terminal with scrollback. Shows response headers and body separately. | ✅ | claim 7635: `verify-live-fetch.sh` PASS with headers-before-body ordering (2026-08-24) | `user/src/fetch.zig`: the terminal stream now buffers through the bare `\r\n\r\n` into a bounded 1 KiB header scratch, emits `--- response headers ---` then `--- response body ---` (serial markers `fetch: headers` / `fetch: body`), with the body tail of a shared TCP segment handled. Pure splitter `header_end` is host-tested. |
| N4 | **Bandwidth display.** TOP.BIN network tab showing bytes sent/received, packets, errors. Updated at 1 Hz using the existing net counters. Shows cumulative and per-second rates. | ✅ | claim 0640: `user/src/top.zig` Network & Bandwidth tab; `verify-live-n4-top-net.sh` PASS on VZ (2026-08-25) | `user/src/top.zig` tab switcher (`ActiveTab { procs, network }`, buttons and 'n'/'p' keyboard shortcuts). Introspects `sys_net_stats` (slot 62) for 1 Hz RX/TX rate deltas, protocol summaries (DHCP, TCP, UDP), and 48-sample bandwidth sparkline history. |
| N5 | **DNS diagnostic tool.** `exec DNS.BIN <hostname> [<server_ip>]` — standalone RFC 1035 UDP DNS query tool for shell diagnostics. Sends queries via `sys_udp_send` (slot 10) and receives via `sys_udp_recv` (slot 11), parsing A-records and response TTLs. | ✅ | claim 0640: `user/src/dns.zig` RFC 1035 UDP client; `verify-live-n5-dns.sh` PASS on VZ (2026-08-25) | New userland app `user/src/dns.zig`. Encodes RFC 1035 A-record queries, manages UDP socket polling, parses answers with domain compression pointers, and outputs resolved IPv4 and TTL. Live gate verifies query against host `--net-dns-respond`. |
| N7 | **TRACEROUTE.BIN.** `exec TRACEROU.BIN [<dest_ip>]` — ICMP route traceroute / path discovery CLI. Probes hops 1..max_hops with ICMP echo requests, measures RTT per hop, formats hop reports, reports summary. | ✅ | claim 0640: `user/src/traceroute.zig`; `verify-live-n7-traceroute.sh` PASS on VZ (2026-08-25) | New userland app `user/src/traceroute.zig` (embedded as `TRACEROU.BIN`). Probes hops, computes hop RTT, formats diagnostics table, and exits status 0. Live gate verifies hop reports and stats on real VZ runner. |
| N8 | **Network status command.** `net status` — prints a concise one-line network summary: IP, Gateway, DNS server, DHCP state, and link state. | ✅ | claim 5931: `kernel/src/monitor.zig`; `verify-live-n8-netstatus.sh` PASS on VZ (2026-08-25) | Adds `cmd_net_status` to monitor. Formats IP, Gateway, DNS server, DHCP state, and link connectivity. Verified live on VZ hardware. |
| N9 | **Connection viewer live.** `NETSTAT.BIN` live refresh with real-time state tracking and transitions. | ✅ | `user/src/netstat.zig` (landed pre-5931 on main; verified against HEAD 2026-08-25) | 1 Hz timer refresh via `EVENT_TIMER` (`refresh_ticks = 4`) driving live TCP connection state, UDP listeners, ARP table, and packet counters. Already on `main` when claim 5931 opened — verified present, not new work. |
| N10 | **Network error UX.** User-friendly human-readable error messages across network stack and applications. | 🔶 | `user/src/fetch.zig`, `user/src/ping.zig` (pre-existing) | Per-app human-readable failures exist (`fetch: connect failed`, `fetch: send failed`, `ping: send to <ip> failed (rc)`). The cited standardized `error: host unreachable` / `error: DNS resolution failed` vocabulary is NOT in the tree — no diff in this PR touches these files. Remaining: a shared error-vocabulary seam. Follow-up issue warranted. |
| N11 | **DOWNLOAD.BIN.** `exec DOWNLOAD.BIN <url> [<out_path>]` — HTTP file download manager saving response payload to persistent disk storage. | ✅ | claim 0640: `user/src/download.zig`; `verify-live-n11-download.sh` PASS on VZ (2026-08-25) | New userland app `user/src/download.zig`. Connects via TCP, streams HTTP response, strips headers, and saves body directly to `/data/` or target file via `ui.file_write`. Live gate verifies disk write and file contents. |
| N12 | **NETPROF.BIN.** `exec NETPROF.BIN` — Network configuration profile manager CLI persisting network profiles to `/data/NET.TXT`. | ✅ | claim 0640: `user/src/netprof.zig`; `verify-live-n12-netprof.sh` PASS on VZ (2026-08-25) | New userland app `user/src/netprof.zig`. Manages profile tables (`name=ip,gw,dns`), parses/serializes configuration, and persists to `/data/NET.TXT`. Live gate verifies profile listing and disk persistence. |
| N13 | **Network-aware application status.** Apps check connection and IP status before network operations. | ✅ done 2026-08-28 — claim 8852 | `user/src/lib/netstatus.zig`, `user/src/ping.zig`, `user/src/fetch.zig` | PING.BIN/FETCH.BIN preflight via one `sys_net_stats` (slot 62) snapshot before the first network op; offline (no IP) and no-route (ARP miss) exit fast with distinct statuses (2/3, 3/4). Class-B gate `tools/verify-live-net-offline.sh` PASS 24/24 (offline boot ×2 apps, no-route boot, online control — N1/N3 shapes unaffected). |
| N14 | **Offline state handling.** Graceful offline handling without hanging or unbounded waiting. | ✅ done 2026-08-28 — claim 8852 | `user/src/lib/netstatus.zig` (message formatting) | The N13 classifier renders the N14 one-liners: `ping/fetch: offline — no IP address (set one: net ip <a.b.c.d> or net dhcp)` and `…: no route to <ip> (resolve first: net arp <a.b.c.d>)`, exit codes distinct per diagnosis. Honest bound: device-absence vs IP-unset are indistinguishable from EL0 (slot 62 has no link flag) — one message covers both, remedies suggested, never guessed. |
| N15 | **Network log viewer.** `net log` — in-memory ring buffer (128 entries) of network events (DHCP transitions, TCP connects/disconnects, ARP resolutions, errors). | ✅ | claim 5931: `kernel/src/net_log.zig`, `kernel/src/monitor.zig`; `verify-live-n8-netstatus.sh` PASS on VZ (2026-08-25) | Fixed ring buffer capturing network events. Exposed via `net log` command. 2/2 unit tests and live VZ gate passing. |
| N16 | **Route inspection.** `net route` — displays the active IPv4 routing table (Destination, Gateway, Interface, Metric). | ✅ | claim 5931: `kernel/src/monitor.zig`; `verify-live-n8-netstatus.sh` PASS on VZ (2026-08-25) | Formats route table with default gateway and interface. Verified live on VZ hardware. |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Network apps** | `user/src/ping.zig` (new) for N1. `user/src/netstat.zig` (new) for N2. `user/src/fetch.zig` (modify) for N3. `user/src/top.zig` (modify) for N4. | M18 done (scrollback for output display). |
| **B — Shell network commands** | `kernel/src/shell.zig` for N5 (connection manager). | M19 done (shell improvements). |

## Notes

1. **ABI budget:** Zero new syscall slots. All apps use existing network
   syscalls (ICMP via `net ping`, TCP via slots 30–33).
2. **BSS budget:** PING.BIN ~64 bytes (stats). NETSTAT.BIN ~512 bytes
   (dashboard state). FETCH.BIN terminal mode ~256 bytes. TOP.BIN network
   tab ~128 bytes. Shell connection state ~64 bytes. Total M26 BSS delta:
   ~1 KiB. Negligible.
3. **Gate shape:** N1: `verify-live-ping.sh` — ICMP round-trip observed.
   N2: `verify-live-netstat.sh` — dashboard output. N3:
   `verify-live-fetch-display.sh` — HTTP response in terminal. N4:
   `verify-live-top-network.sh` — bandwidth display. N5:
   `verify-live-net-connect.sh` — connection lifecycle.
4. **PING.BIN implementation:** The ICMP echo path reuses the kernel's
   existing ICMP infrastructure. The app sends echo requests through the
   kernel's `net ping` monitor command path (which already sends ICMP echo
   and prints the reply). The app wraps this with timing and statistics.
5. **Scope exclusions:** No HTTPS (no TLS stack). No HTTP server. No
   WebSocket. No network file system. No packet capture / tcpdump. This
   is diagnostics and basic interactivity, not infrastructure.
