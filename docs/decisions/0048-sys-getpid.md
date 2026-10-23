# ADR 0048: sys_getpid — an unforgeable self-pid answer

- Date: 2026-10-13
- Status: **Accepted** — shipped by card #2158: slot 87 is live
  (`kernel/src/syscall.zig:185,1143`). Card #2158 was explicitly an ABI
  decision; this ADR landed before the kernel code in the same PR.
- Card: **#2158** (audit-verified: `WmPeers` resolves self-pid by first
  `sys_procs` name match, so a second instance of any app misroutes every
  WM_RPC ack to the first instance's mailbox).
- Related: ADR 0007 (syscall ABI), ADR 0015 (window-server seam), ADR 0024
  (principals — `sys_principal` reports uid/caps, deliberately not the pid),
  ADR 0047 (the v2 `sys_procs` row).

## Context

`sys_ipc_recv` resolves the caller's own ring server-side (`ipc.go:17-18`
documents "no self-pid argument on the wire"), but nothing answers "who am
I". The consumers that need a self-pid — `vi.WmPeers` (the `reply_to` field
of every WM_RPC frame), `vi`'s lease holder checks, the Zig `ui.wm_peers` —
each re-derive it by scanning `sys_procs` for a RUNNING row whose name
equals the binary name. A name is not an identity: the kernel derives
process names from the FAT file name and nothing dedupes them, so two
`NOTE.ELF` rows are legal and *reachable* (the duplicate-tab chord
Ctrl+Shift+D, the launcher, a second GOSH exec). The first match wins in
Go, the last in Zig — both wrong for the second instance, silently.

## D1. Slot 87: `sys_getpid()` → the caller's pid or -EINVAL

```
x8 = 87   args: none   x0 = pid (> 0) | -EINVAL
```

- Zero arguments, zero copies: the kernel resolves the pid from the current
  task (`process.find_by_task(scheduler.current_id())`), the same
  authoritative answer `sys_ipc_recv` already uses to pick the ring.
- A non-process caller (an EL1h task) is `-EINVAL` — the same refusal
  `sys_principal` (slot 68) gives, for the same reason: there is no pid to
  fabricate.
- A thread asks about its *process*: `find_by_task` maps task→process, so
  an M65 worker thread and its main task read the same pid.
- Kernel domain lock `k` — the registry/misc group `sys_procs` already
  rides; no new domain, no shared state touched beyond a table read.

## D2. Why a slot and not existing surface

- **`sys_procs` v2 (ADR 0047) cannot carry "self".** The 80-byte row is
  fully allocated (header, v1 fields, counters, denominators); a self flag
  would need a v3 row or a flags field, and it answers the question at
  O(rows) cost with a stale-by-one-snapshot answer anyway.
- **`sys_principal` (slot 68) is read-only identity but not pid.** Its
  frozen 8-byte row is uid/caps; growing it is the same frozen-row problem
  in miniature, and pid is not a principal attribute (ADR 0024 keeps
  identity and addressing separate).
- **`sys_wmctl` (slot 65) is the WM seam.** Self-pid is not a WM question —
  the lease checker and any future ack-addressed protocol need it without
  a window server. A wmctl subcommand would couple every client of
  self-pid to the seat's availability.
- **The precedent row is already dense.** Slots 0–86 are all spoken for;
  87 is the next free number, additive, no renumbering (ADR 0007's frozen
  row rule).

## D3. Caller contract — the register wins, the scan survives for peers

- `vi.WmPeers` asks the kernel first (`vi.SelfPid`). A positive answer is
  authoritative and skips the name scan *for self* — the scan still runs
  for the seat row's protocol name and still serves as the only answer
  where no kernel exists (host tests, `-ENOSYS`).
- The Zig `ui.wm_peers` does the same: `sys_getpid` first, name-scan
  fallback. Its remaining name-based WM resolution (the pre-#2079 shape)
  is a separate defect, explicitly out of this card's scope.
- `reply_to` remains an 8-bit wire field (`WmRpc.ReplyTo`); a pid that
  cannot fit already refuses at `fitsWire8`, unchanged.

## Consequences

- Second instances of every Go app stop leaking their WM_RPC acks to the
  first instance: the M97g-F2 bind completes, declares/retitles/toasts
  work on the duplicate tab.
- The name-scan flake discipline (M56d) is untouched where it still
  matters: seat-protocol classification.
- One new frozen ABI row (name + zero-arg shape), one handler, a `doms_of`
  entry, the generated `slots_gen.go` mirror, and the `syscalls` report
  grows one line. No changes to any existing slot's semantics.
