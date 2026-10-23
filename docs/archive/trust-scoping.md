> ARCHIVED 2026-10-23 — design record for the shipped M50 trust baseline;
> the binding contract is ADR 0024. Not an active plan.

# Trust & isolation baseline (M50) — scoping and gated card split

Status: **DONE 2026-09-11 — design accepted (ADR 0024); TS1–TS5 all landed
(TS3 last, issue #1137); umbrella #1133 closed** ·
Date: 2026-09-11 · Milestone **M50** · Umbrella **#1133** · Design card
**#1134** (TS0) · Depends on: M46 remote (**#1145**, merged) and M47
crypto (**#1148**, merged), ADR 0010 (file ABI), ADR 0016 (owner-check
precedent), ADR 0022 (M46 seam), ADR 0023 (M47 primitives).

> This document is the milestone's build order. It says what each TS card
> delivers, how it is verified, and what is deliberately **not** here. The
> binding design decisions are in **ADR 0024**; this document does not
> restate them, it applies them.

## The one-line pitch

A minimal trust boundary for a network-connected daily driver: every
process has a named principal, files have owner/mode bits enforced at the
syscall seam and the direct-consumer seam, secrets are a class the file
ABI cannot read, and the remote door stops accepting a reusable in-band
secret — it demands a fresh challenge answered with M47 HMAC or Ed25519
before a single byte reaches the shell.

## Why now, and why this shape

- **The prerequisites just landed.** M46 (#1145) built the auth seam and
  an in-band shared secret; M47 (#1148) shipped HMAC-SHA256, Ed25519,
  X25519, ChaCha20-Poly1305, and constant-time helpers. ADR 0022's first
  open item explicitly hands the upgrade to M50 (#1138).
- **The host share is the daily filesystem and has zero access control.**
  Any process can open any share path; the only check is the per-handle
  read/write flag (`kernel/src/file_table.zig:424`, `:483`). The monitor
  and several kernel consumers bypass even that (`monitor.zig:1308-1330`,
  `exec.zig:289-294`, `settings.zig:428-466`).
- **A trust model that cannot be tested is prose.** Every card lands
  class-A tests plus a declarative class-B spec (AGENTS.md M40 GF6), and
  no card may change the boot default.
- **Honesty over theatre.** Single-user means owner checks mostly pass
  today; ADR 0024 D3 says so. What changes behavior immediately is the
  secret class, `uid_system`-owned paths, and the remote handshake.

## Layout (expected files; implementation may adjust within its card)

```
kernel/src/process.zig            uid + caps fields, assignment at create
kernel/src/trust.zig              NEW: bounded metadata table + check()
kernel/src/file_table.zig         trust.check at every entry point
kernel/src/monitor.zig            explicit kernel_actor(); admin spawn
kernel/src/syscall.zig            slots 68-71 + gated existing handlers
kernel/src/terminal.zig           delegated net-auth state machine (TS4)
kernel/src/tcp.zig                payload/segment bound raise (TS4)
kernel/src/settings.zig           secrets store pattern (TS5 file)
user/src/lib/netauth.zig          NEW: net handshake client loop (TS4)
user/src/sh.zig, user/src/term.zig  front-end wiring (TS4)
user/src/lib/netargs.zig          `net` mode parsing (TS4)
host/vm-runner/Sources/VMRunner/main.swift  Stage-0 HMAC (TS4)
tools/lib/vgate-client.py         `--hmac-secret` (TS4)
tools/gate/specs/live-trust-*.spec, live-secrets.spec, live-remote-auth2.spec
OWNERS.TXT / SECRETS.TXT          share files (fixtures in gates)
```

## Enforcement map (ADR 0024 D4/D6/D10)

| Seam | Who is asking | What decides |
|---|---|---|
| `sys_file_*` / `sys_dir_list` (slots 23–27, 34–37) | EL0 process | `trust.check(actor, partition, path, want)` — owner/other mode bits, default policy, secret-class deny |
| `sys_file_mode` (new 69) | owner or `CAP_FS_ANY` | chmod only; no chown |
| Monitor `vf` verbs | EL1h | explicit `kernel_actor()`; ordinary paths allowed, secret-class denied |
| Kernel consumers (settings, exec, history, tombstone, redirect) | uid_system | explicit `kernel_actor()` per call site (audited in TS2) |
| Net front-end pump | remote client | D6 challenge-response: fresh 32-byte challenge, M47-verified verdict, 10 s deadline, fail closed |
| `sys_kill` (29) | process | self/same-uid allowed; cross-principal needs `CAP_PROC_ADMIN` |

## Card split and acceptance

| Card | Deliverable | Class-A acceptance | Class-B acceptance | Boot default |
|---|---|---|---|---|
| **TS1** #1135 | `Process.uid`/`caps` assigned at `process.create`; `sys_principal` slot 68; `whoami`/`id` builtins; monitor principal report; ADR 0007 table update | default is `uid_user`/no caps; exec preserves; no syscall can set uid/caps; `sys_procs` snapshot stays byte-frozen | `live-trust-whoami.spec`: guest runs `whoami` → `uid=1000 user`, `id` lists caps 0; `sys_principal` probe agrees with `whoami` | no wire/format change |
| **TS2** #1136 | `kernel/src/trust.zig` (bounded table, `check`, `OWNERS.TXT` `#v1` load/save); checks in `file_table`; explicit `kernel_actor()` at every direct consumer; secret flag; slot 69 `sys_file_mode`; rename/delete semantics | allow/deny matrix (owner vs other, r/w, dir list, create/delete/rename), default policy, malformed entry fails closed, table-full `ENOSPC`, round-trip parse/serialize | `live-trust-modes.spec`: host seeds an `OWNERS.TXT` fixture with a `uid_system`-owned `0600` file; uid_user `cat` → `EACCES`; an ordinary owner file reads and the owner `chmod` succeeds; the guest-written `OWNERS.TXT` is inspected on the host; the rest of the matrix is class-A | empty table reproduces today's behavior exactly |
| **TS5** #1139 | `SECRETS.TXT` bounded store (secret-class via TS2); `sys_secret_get` slot 70; redaction of secret buffers from strace, monitor output, snapshots, tombstones; `secrets` command prints names only; host-side provisioning documented | bounds/round-trip; file-ABI read denied for every actor; `sys_secret_get` returns values only to the owning principal; redaction unit tests | `live-secrets.spec`: host seeds a known value; guest `secrets` lists the key name; `cat SECRETS.TXT` denied; full serial capture is `serial-absent` the value | no secret is read at boot |
| **TS4** #1138 | Delegated challenge-response (`sys_tty_net_auth` slot 71); pump state machine + `payload_max` 64→192; `user/src/lib/netauth.zig`; SH/TERM wiring; Stage-0 host HMAC via CryptoKit; `vgate-client --hmac-secret`; shared-secret fields and `secretEq` deleted; `live-remote` re-pointed to `open`; `live-remote-auth` retired | protocol/state tests over `NetSeam` (`terminal.zig:722-739`): fresh challenge, wrong MAC reject, captured-handshake replay reject, deadline trip, key zeroize, strace redaction, bounds fit | `live-remote-auth2.spec`: wrong MAC → `auth failed` + reset; right MAC drives the shell; replayed prior capture rejected; explicit `open` still accepts; Ed25519 signature verified in a class-A pinned-vector test (its class-B host helper is a stretch) | nothing listens unless a process asks |
| **TS3** #1137 | Caps enforcement: `sys_kill` cross-principal gate, default-deny table, exec preservation, monitor admin spawn for tests | gate-table tests; cross-uid kill denied; self/same-uid allowed; no elevation syscall exists; admin spawn is monitor-only | `live-trust-caps.spec`: monitor spawns a system-principal probe; a uid_user probe's kill → `EACCES`; same-uid kill still works | default all-uid_user fleet unchanged |

Each card is its own implementation PR (or one stacked session), updates
ADR 0007's table and `implemented_count` where it adds a slot, regenerates
`docs/gate-fleet-inventory.md` when it adds a spec, and presents
`boot-default-unchanged` evidence (the existing class-B suite green).

## Implementation order

**Recommended: TS1 → TS2 → TS5 → TS4 → TS3.**

```
TS1 identity ──► TS2 permissions ──► TS5 secrets ──► TS4 authenticated remote

  └────────────► TS3 syscall gating (independent after TS1)
```

- **TS1 first** — uid is the substrate every other card keys off; nothing
  else can be tested without it.
- **TS2 second** — enforcement and the secret class come from the same
  metadata table; TS5 needs the class, TS4 needs TS5.
- **TS5 third** — TS4's acceptance requires keys from the store, not argv
  (the M46 CLI secret would otherwise appear in the transcript, exactly
  what TS5 forbids).
- **TS4 fourth** — consumes M46 (merged) + M47 (merged) + TS5. It touches
  `tcp.zig` bounds, so it must run the full remote/terminal gate fleet.
- **TS3 last, or anywhere after TS1** — the syscall gate is independent;
  it is placed last only because its cross-principal proof is easiest once
  TS2's admin spawn and TS5's store exist. If a session wants an early
  visible win, TS3 can be pulled forward.

This ordering differs from the umbrella's card *listing* (TS1–TS5) by
moving TS5 ahead of TS4 and TS3 last; the listing is not a dependency
statement, and the swaps are forced by the key-provisioning and proof
requirements above.

If a single session cannot land all five, the umbrella rule (#1133) applies:
land the smallest complete slice (TS1 with its gate) and leave the rest on
the tracker — the cards already exist as #1135–#1139.

## Threat model

**Protected:** guest terminal bytes (nothing reaches the shell before the
verdict), guest file policy between principals and for the secret class,
the remote door (fresh challenge, no reuse of a captured handshake), and
credentials (never in argv, never in logs).

**Not protected, by decision:** confidentiality and integrity of the
post-auth stream (plaintext, no TLS), a live MITM relay during the
handshake, availability (floods on the TCP/share paths), the host as a data
authority (the share is a dumb path-sandboxed folder), side channels (ADR
0023 D3's stated limit), and multi-user isolation (one EL0 uid today).

## Non-goals (explicit)

- **No TLS, no SSH, no session encryption** — a later card may build
  ChaCha20-Poly1305 over the same seam; M50 authenticates only.
- **No multi-user login, groups, ACLs, or setuid** (ADR 0024 rejected).
- **No host-side enforcement** — the wire and the share stay unchanged.
- **No syscall renumbering** — new slots append; ADR 0007's freeze holds.
- **No `SETTINGS.TXT` format change** and no secret keys in it.
- **No cross-connection throttling** (open issue, ADR 0024).

## Risks / open questions

- **Latent enforcement.** With one EL0 uid, owner checks pass trivially;
  TS2's behavior change is the secret class and system-owned paths. Every
  card must state the strongest claim it can actually prove.
- **Case-insensitive host share vs. byte-exact metadata keys.** TS2 must
  resolve this (canonicalization or exact-name tracking) before claiming
  deny-by-default is airtight.
- **`payload_max` 64 → 192 touches the M46/M45 fleet.** TS4 owns the
  change and must run every remote/terminal spec, not just its own.
- **Delegated auth assumes the attached process answers.** A hung or
  malicious process gets a bounded 10 s deadline and a failed connection,
  never a bypass; the class-A state machine must pin this.
- **Host CryptoKit dependency is new** (the runner imports no crypto
  framework today, observed). If the host toolchain balks, the fallback is
  a small Swift HMAC built on the pinned RFC 4231 vectors — a recorded
  finding, not a silent change.
- **Secret provisioning UX** is host-edits-a-share-file until a
  non-echoing guest path exists; `sys_secret_set` stays deferred.
