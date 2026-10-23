> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone twelve march — userland network applications (living tracker)

## Where we are

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-twelve's per-card detail and collision-free agent split, following
> the [`march-m6.md`](march-m6.md), [`march-m7.md`](march-m7.md),
> [`march-m8.md`](march-m8.md), [`march-m9.md`](march-m9.md),
> [`march-m10.md`](march-m10.md), and [`march-m11.md`](march-m11.md) pattern.
> A card's row flips to ✅ only with real observed class-B evidence, never
> code-complete alone.

Milestones zero through eleven delivered a complete freestanding desktop operating
system on Apple silicon: an AArch64 kernel with preemptive multitasking, per-process
virtual memory, FAT32 kernel/user storage, virtio-net transport, virtio-gpu windows
(Driving Award), USB xHCI input, human interface tooling, interactive EL0 events,
and a graphical desktop platform with consumer applications (`CALC.BIN`, `NOTEPAD.BIN`,
`TOP.BIN`, `DESKTOP.BIN`), `sys_exec` (slot 28), and `sys_kill` (slot 29).

Milestone twelve connects userland applications to the network with a **bounded
TCP syscall ABI (ADR 0007 slots 30–33), RFC 1035 DNS resolution, and standalone
network applications (`TCP.BIN`, `FETCH.BIN`, `CHAT.BIN`)** (GitHub Issues #148, #149, #150).

The cards, in order:

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| N0 | **Architecture & Network ABI contract (ADR 0012).** Normative specification for userland networking: TCP syscall semantics (`sys_tcp_connect`, `sys_tcp_send`, `sys_tcp_recv`, `sys_tcp_close` on slots 30–33), DNS RFC 1035 packet schema & resolution flow, error code mapping (`ECONNREFUSED`, `ETIMEDOUT`, `ENOTCONN`, `EINVAL`, `EFAULT`), and process lifecycle teardown. Docs only — no code. | ✅ done | `docs/decisions/0012-userland-network-applications.md` | Gate: ADR 0012 accepted. |
| N1 | **Userland TCP syscall seam (Issue #148).** Implement `sys_tcp_connect` (slot 30), `sys_tcp_send` (slot 31), `sys_tcp_recv` (slot 32), and `sys_tcp_close` (slot 33) in `kernel/src/syscall.zig` and `kernel/src/tcp.zig` with `uaccess` copy helpers. Proof program `TCP.BIN` (`user/src/tcp_client.zig`) connects to `10.0.0.2:9999`, sends 5 bytes, receives echo, closes, and exits 18. | ✅ done | `kernel/src/syscall.zig`, `user/src/tcp_client.zig`, `tools/verify-live-net-tcp-syscall.sh` | Gate: `tools/verify-live-net-tcp-syscall.sh` PASS on VZ hardware. |
| N2 | **Bounded DNS client (Issue #149).** RFC 1035 UDP query client in `kernel/src/dns.zig` targeting DNS port 53. Encodes standard A-record queries, parses DNS responses, extracts IPv4 addresses. Monitor command `net dns <hostname>` + runner `--net-dns-respond`. | ✅ done | `kernel/src/dns.zig`, `kernel/src/monitor.zig`, `tools/verify-live-net-dns.sh` | Gate: `tools/verify-live-net-dns.sh` PASS on VZ hardware. |
| N3 | **`FETCH.BIN` & `CHAT.BIN` capstone applications (Issue #150).** Standalone EL0 HTTP/1.0 client `FETCH.BIN` (`user/src/fetch.zig`) retrieving web content over TCP port 80, and peer-to-peer graphical chat app `CHAT.BIN` (`user/src/chat.zig`) combining `ui.zig` micro-widgets with UDP messaging. | ✅ done | `user/src/fetch.zig`, `user/src/chat.zig`, `tools/verify-live-fetch.sh` | Gate: `tools/verify-live-fetch.sh` PASS on VZ hardware. |

## Agent split / collision rules

- **N0** (claim done): owns `docs/decisions/0012-userland-network-applications.md`
  and ADR 0007 syscall table amendments. Docs only.
- **N1** (future claim, Issue #148): owns `kernel/src/tcp.zig`, `kernel/src/syscall.zig` slots 30–33,
  `user/src/tcp_client.zig`, and `tools/verify-live-net-tcp-syscall.sh`.
- **N2** (future claim, Issue #149): owns `kernel/src/dns.zig`, `kernel/src/monitor.zig` `net dns`,
  `host/vm-runner/Sources/VMRunner/PacketCapture.swift`, and `tools/verify-live-net-dns.sh`.
- **N3** (future claim, Issue #150): owns `user/src/fetch.zig`, `user/src/chat.zig`,
  desktop launcher integration, and capstone gate `tools/verify-live-fetch.sh`.
- Cross-cutting docs (`status.md`, `gate-inventory.md`) are updated per card
  at claim close-out.
