# Roadmap archive — Milestone twelve — userland network applications

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

### Milestone twelve — userland network applications (**DONE 2026-08-16, PR #160**)

> Connect userland applications to the network with a clean TCP syscall seam (ADR 0007 slots 30–33),
> RFC 1035 DNS resolution, and standalone network applications (`TCP.BIN`, `FETCH.BIN`, `CHAT.BIN`).
> See [`docs/march-m12.md`](march-m12.md) and [`docs/decisions/0012-userland-network-applications.md`](../decisions/0012-userland-network-applications.md) (Issues #148, #149, #150).

- **N0 — Architecture & Network ABI contract (ADR 0012).** Normative specification
  for userland networking: TCP syscall semantics (`sys_tcp_connect`, `sys_tcp_send`, `sys_tcp_recv`, `sys_tcp_close` on slots 30–33),
  DNS RFC 1035 packet schema, and process lifecycle teardown.
- **N1 — Userland TCP syscall seam (Issue #148).** `sys_tcp_connect` (slot 30), `sys_tcp_send` (slot 31),
  `sys_tcp_recv` (slot 32), `sys_tcp_close` (slot 33) in `kernel/src/syscall.zig` + `kernel/src/tcp.zig`.
  Proof program `TCP.BIN` (`user/src/tcp_client.zig`). Live gate: `verify-live-net-tcp-syscall.sh`.
- **N2 — Bounded DNS client (Issue #149).** RFC 1035 UDP query client in `kernel/src/dns.zig` on port 53 to
  resolve domain names. Monitor command `net dns` + runner `--net-dns-respond`. Live gate: `verify-live-net-dns.sh`.
- **N3 — `FETCH.BIN` & `CHAT.BIN` capstone applications (Issue #150).** **[Capstone Gate]**
  HTTP/1.0 client `FETCH.BIN` fetching web text over TCP port 80, and peer-to-peer graphical chat app `CHAT.BIN`
  combining `ui.zig` micro-widgets with UDP messaging. Live gate: `verify-live-fetch.sh`.


See [`march-m12.md`](march-m12.md) for the per-card tracker.
