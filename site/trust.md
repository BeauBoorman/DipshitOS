---
title: Trust & security
parent: architecture
status: published
tags: [architecture, trust, security, crypto]
---

# Trust & security

The trust model starts from an unusual place for a hobby OS: **the host
is an untrusted data plane, every guest principal is explicit, and every
denied thing answers with a name.** There is no implicit privilege to
invent and no silent allow anywhere in the tree — a refusal is a named
errno plus a receipt, and the standing gates exist to prove the
*negative* cases as rigorously as the positive ones. This page walks the
stack from raw primitives up through verified boot and the grant
enforcement a confined app lives under.

## The primitives

Everything above rests on a deliberately small shelf
([ADR 0023](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0023-crypto-primitives.md)):
a freestanding, caller-buffered, allocation-free library under
`user/src/lib/crypto/` — streaming SHA-256/SHA-512 and HMAC, ChaCha20
and the RFC 8439 ChaCha20-Poly1305 AEAD, X25519, Ed25519 sign/verify,
and constant-time helpers (`ct_eq`, `ct_select`, `wipe`). `std.crypto`
is deliberately unused; every primitive is pinned to published RFC/NIST
known-answer vectors as class-A tests, and the library carries no
randomness at all — entropy stays the kernel's job.

The kernel keeps its own ChaCha20 for the CSPRNG rather than importing
the userland file (module-path and direct-`zig test` gates forbid it),
but the two cannot drift: both pin the same RFC 7539 vectors, so either
straying fails its own tests. Userland entropy comes through slot 72
`sys_getrandom`, and since the M97 audit it **fails closed**: an
unseeded CSPRNG answers `EAGAIN` and writes nothing rather than serving
the deterministic fallback stream (`live-entropy-refusal`).

The stated limit, inherited by everything below: this is
cache/branch-discipline constant-time, not side-channel-proof — Zig is
not a constant-time compiler, and verification paths may branch on
public data.

## TLS 1.3

[ADR 0029](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0029-tls.md)
kept the whole TLS stack **in-tree** — no third-party TLS or X.509
library, because vendoring would put the most security-critical code in
the tree outside its own review and gate discipline. The shelf the
handshake needed — HKDF (RFC 5869), SHA-384/HMAC-SHA384, AES-128/256 and
AES-GCM, Montgomery bigint RSA and ECDSA P-256/P-384 — was built
in-tree and pinned to independently extracted vectors, a discipline that
caught ten construction defects before interop ever ran.

The client offers the RFC-mandatory suite `TLS_AES_128_GCM_SHA256` with
x25519 — nothing else, so a negotiated handshake can't smuggle a
different suite past the assertion. The handshake is a named state
machine, and the certificate path **fails closed** in ways that were
live bugs first: a self-issued certificate may not anchor its own
chain, a parsed certificate is a view (anything outliving the buffer is
copied), and an unknown *critical* extension fails the chain rather
than being ignored. Observed interop: real handshakes against four
independent peer implementations and eight public endpoints, with five
hostile or broken peers refused. The live consumers are the Go fleet —
`GOFETCH.ELF`, `WEB.ELF`, `GOTGIT.ELF` dial HTTPS in-process through
`user/go/tls` (`just gate go-fetch-https` pins the happy path plus the
name/expired/chain negatives; `go-git` pins clone-over-https). No
revocation (OCSP/CRL) exists — a named gap, not a hidden one.

The server half exists too: `GOHTTPD.ELF` terminates TLS 1.3 and serves
HTTPS (`live-httpd`), so the guest can be the endpoint as well as the
client.

## SSH-2

The SSH client is a userland program on the same primitives ([ADR
0025](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0025-ssh.md)):
`GOSSH.ELF` over `user/go/sshlib` — the original Zig `SSH.BIN` was deleted
when the Go client landed — offering exactly one modern
profile: `curve25519-sha256` KEX, `ssh-ed25519` host keys and userauth,
and `chacha20-poly1305@openssh.com` as the cipher (a *different*
construction from the RFC 8439 AEAD — split keys, packet-sequence
nonce — built and vector-pinned as its own primitive). Host-key pins
live in a plain, auditable `SSH/KNOWN_HOSTS` file; the client's private
key is a `SECRETS.TXT` seed read through slot 70 and wiped after use.

The interop claim is **real-OpenSSH, end to end**: against the host's
`/usr/sbin/sshd` the guest negotiated the suite, verified the server's
host-key signature, passed `publickey` userauth, and read remote stdout
plus `exit-status`. Session bounds are honest: a session hitting 1 GiB
or 2²⁰ packets per direction disconnects by name rather than silently
continuing past its rekey horizon.

The server direction exists as `GOSSHD.ELF`: pinned `SSH/AUTHORIZED_KEYS`
publickey auth, a session that runs `GOSH.ELF -c`, and concurrent
sessions inside the bounded slot-80 socket table — `live-ssh-server`
holds an agentd listener, two SSH sessions and an outbound web fetch
alive on three distinct 5-tuples at once. The gate set is
`live-ssh-endpoint`, `live-ssh-negative`, `live-ssh-nocred`,
`live-ssh-packet`, `live-ssh-server`.

## Identity and isolation

[ADR 0024](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0024-trust-and-isolation.md)
gave the system principals. Every process carries a `uid` and a `caps`
bitmask, assigned at `process.create` and preserved by `exec`; there is
**no syscall to raise either** — no setuid bit, no privilege setter —
so the only way to gain privilege is for the kernel itself to create
the process. Three principals exist: `uid_system` (0, kernel actors and
the monitor), `uid_user` (1000, every ordinary EL0 process), and
`uid_agent` (2000, assigned at exec to `AGENTD.ELF` images and inherited
by their children — with the asymmetry that `uid_user` may signal
`uid_agent`, never the reverse). The two capability bits are
`CAP_FS_ANY` (bypass file checks; kernel-internal) and
`CAP_PROC_ADMIN` (act on another principal's processes — `sys_kill`
cross-uid is `EACCES` before any state check, and the monitor is never
a target).

**Files have owners and modes** keyed on normalized paths in a bounded
kernel table, persisted as `OWNERS.TXT` — fail-closed like the rest of
the metadata surface: a malformed line *denies* its path rather than
defaulting, keys compare case-insensitively (over-application is
fail-closed, never a bypass), and the file is self-protected by
construction so EL0 cannot author the table it would be judged against.
The honest caveat is written into the ADR: at `uid_user`-owns-everything
defaults most owner checks pass trivially; what has teeth is the
`secret` class and `uid_system`-owned paths.

**Secrets are a different class of file.** `SECRETS.TXT` entries are
denied to the entire file ABI — the only in-guest reader is
`sys_secret_get` (slot 70), which serves the caller's own rows into
caller memory and is excluded from strace. The never-logged contract is
asserted: secret bytes may not appear in serial, history, env, tombstones
or `sys_procs` output. Rows can additionally be **app-bound** — served
only when the caller's recorded image name matches the allowlist *and*
that image is `uid_system`-owned — because a name alone is forgeable.
`GRANTS.TXT` now shares the class for integrity (below).

**The remote door authenticates by challenge.** The old shared-secret
line was replaced by `VIRELAIOS-AUTH/1`: the kernel pump mints a fresh
32-byte challenge and gates byte delivery on a userland verdict —
HMAC-SHA256 or Ed25519 over a domain-separated message — verified by
the attached process against store credentials. Reject, malformed, or a
10-second miss answers `auth failed` and resets the connection;
pre-auth bytes never reach the input queue. Fail closed by default:
with a provisioned credential auth is mandatory, and `open` mode must
be asked for explicitly (`live-remote-auth2`).

**Agents are first-class principals** ([ADR
0052](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0052-agent-identity.md),
on the ADR 0044 channel). `AGENTD.ELF` serves JSON Lines on guest TCP
4747, and each outside agent is a row in `AGENTS.TXT` — a public-key
keyring of `agent=<id> key=<pub> caps=<csv>` plus `revoked=<pub>`,
host-provisioned, `uid_system`-owned and world-readable; **the private
half never enters the guest at all**. The `virelai-agent/2` handshake
signs the challenge *and* the claimed id, so an id can't be swapped
under a captured signature; refusals name `agent_unknown`,
`agent_revoked`, `auth_failed`. Each row's `caps=` grants a subset of
the shared vocabulary (`file window audio timer memory process debug
net term`) mapped to verbs — a missing cap answers `cap_required:<cap>`
non-fatally — and **every dispatch, allowed or refused, leaves a
MAC'd receipt** in `AGENT/AUDIT/` the agent cannot reach through its
own verbs. `go-agentd` and `live-agent-loop` are the gates.

## The grant system

The `caps=` field in `APPS.TXT` is documented DECLARATIVE and stays so
forever — the file is guest-writable and can never be an enforcement
source. Enforcement lives where the file ABI cannot write: a
**kernel-owned grant table** of `(name, sha256, words)` rows ([ADR
0054](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0054-measurement-and-grants.md)
Part II, landed through M113/M116). One word means one group of ADR
0007 slots:

| Word | Slot groups it gates |
|------|----------------------|
| `file` | file ops 23–27, 34–37, 69, 77, 79 |
| `window` | window/event ops 12–22, 46–53, 55, 58, 61, 65 |
| `audio` | 42–45 (and the capture seam 91/92) |
| `timer` | 40, 41 |
| `memory` | 63, 64 |
| `process` | exec/wait/kill/IPC/thread ops 5–8, 28, 29, 54, 56, 57, 68, 73–75, 81–83, 87 |
| `debug` | console ops 0, 1, 3 |
| `net` | UDP/TCP/DNS/stats + slot-80 open-class ops (listen, DNS, connect) |
| `term` | 67, 71 |

Rows have two sources, neither writable through the file ABI: **base
rows compiled into `KERNEL.BIN`** — transitively verified by the boot
chain, since a different table is a different kernel digest — and
**`GRANTS.TXT` on the share**, registered secret-class by construction
(exactly like `SECRETS.TXT`) so the only EL0 write path is the
seat-gated admin slot (89: read/write/denials), which refuses the app
the row names and requires the registered WM seat or `CAP_PROC_ADMIN`.

**Exec measures.** When a row names the binary being exec'd, the kernel
SHA-256s the image bytes it already holds: match → the row's word set
applies (a narrowing of the baseline); mismatch → `grant_stale` and no
process is born, never a fall-open; no row → the baseline floor. A
`*`-wildcard row may only *narrow* — a name-only row granting beyond
baseline would be claimable by any renamed binary, so the parse refuses
it at load.

**Audit first, then enforce.** The `mode=` header runs `audit` by
default — the kernel applies `grant_stale` (a real refusal; it protects
row integrity) but emits `audit:<word>_denied` receipts for would-be
denials without refusing the calls. The fleet was audited in that mode,
and the observed word sets became the compiled baseline
(`image/fleet-grants.txt` → generated `kernel/src/grant_fleet.zig`: one
row per shipped app, mask ⊇ observed). The owner then flipped to
`enforce`: the ambient floor became baseline-minus-`file`/`audio`/`net`,
undeclared words answer named `EACCES`, and the whole fleet still
boots and seats under it (`live-grant-enforce`).

**Scoping narrows further.** A row may qualify `net` with a `host:port`
allowlist (≤4 entries per row, v6 prefixes supported) and `file` with
canonical `/host`-`/disk` path scopes — scope only removes reach. A
publisher declares desired words as a signed `ReleaseCaps` in its
release manifest (a *request*, never power); STORE proposes the row,
and the **seat consent modal** writes it — a `g` keystroke produces a
hash-bound `GRANTS.TXT` row through the seat-gated slot. `GOTOP.ELF`'s
Trust tab renders posture and denial receipts live. Gates:
`live-trust-grants`, `live-grant-enforce`, `live-net-policy`,
`live-install-consent`.

## Verified and measured boot

Virtualization.framework exposes no TPM — observed, grepped, not
guessed — so "measured boot" in the TPM sense is impossible, and the
anchor is **verified boot** instead ([ADR 0054 Part I]). The runner can
arm UEFI Secure Boot with a custom platform key and a db containing the
**Authenticode digest** of `BOOTAA64.EFI` — and the probe proved what
that buys: an image whose digest isn't enrolled is refused by *firmware*
— the VM halts with zero serial bytes and no markers, a refusal outside
anything the guest can catch or downgrade.

The chain composes: firmware verifies the loader; **the loader verifies
`KERNEL.BIN`** against a compiled-in raw SHA-256 and refuses
`kernel_hash_mismatch` — return-to-firmware halt — rather than jumping;
and the kernel publishes a `RCPT stage=<s> sha256=<hex> verdict=<v>`
receipt line per stage (a refused boot's evidence is the receipt's
absence). Because the compiled base grant rows live in `KERNEL.BIN`,
the chain transitively verifies the grant table too. The whole feature
is opt-in: `--secure-boot` flags on enrolls and verifies; **flags off
is byte-identical**. `just gate live-verified-boot` runs all four legs
— canonical boot with host-recomputed digests, tampered-loader halt,
tampered-kernel refusal, and the flags-off path.

## The audit that hardened it

M97 was a read-only audit of every trust boundary — seven lanes of
findings consolidated into ~40 deduplicated issues, every Sev-A and
Sev-B owned and fixed on main. The fixes are the kind that only an
audit finds: `sys_getrandom` serving a deterministic fallback stream
when unseeded (now `EAGAIN`); secrets readable by any `uid_user` app
(now app-bound rows with self-protected metadata); diagnostic/log paths
forgeable across apps (now label-bound to the recorded image); a
privilege-setter audit across the whole slot table. The posture since
is that the trust surface is *inventoried*, not assumed.

## Standing negatives

Two gates exist to keep the denials honest, not the allowances:

- `just gate live-sandbox-negatives` — a corpus of probe binaries
  under `mode=enforce`: undeclared words refused by name while declared
  ones land, a stale hash-bound row refused `grant_stale`, poisoned row
  shapes (bad digest, unknown word, bad scope, extra field) all failing
  closed at exec, and every row-write escape — the slot-89 read, a
  cross-app write, a self-row write, a file-ABI `GRANTS.TXT` write —
  answering `EACCES` with the share file byte-identical afterward.
- `just gate live-trust-journey` — the composed acceptance: a signed
  third-party app installs through the real STORE pipeline, the seat
  consent prompt stands, the typed `g` writes the hash-bound row, and
  the app runs *inside* its words — declared calls land, the undeclared
  one answers `refused:audio_denied` + `EACCES`, every grant-table
  escape refused, and a second boot proves consent is durable state,
  not a per-boot gesture.

<Aside kind="warning">

**LIMITATION.** The honest edges, stated as the ADRs state them: the
model is single-user (owner checks are mostly vacuous at defaults; the
teeth are the secret class, `uid_system` paths, and grants); the remote
door's `VIRELAIOS-AUTH/1` handshake authenticates but does *not*
encrypt — plaintext after auth, which is why SSH exists for
confidential sessions; audit receipts are tamper-*evident* (MAC'd), not
tamper-*proof* against an agent holding `gosh.run`; one `uid_agent`
principal covers all agents; and AES is table-based, so its timing
shares the crypto shelf's stated constant-time limit.

</Aside>

## Where next

- [[userspace|Userspace & syscalls]] — the ABI every check sits on.
- [[go-runtime|The Go runtime]] — `sys_getrandom`, secrets, and the `vi` grant surface.
- [[devloop|The in-guest dev loop]] — signed releases, keyrings, and install consent.
- [[capabilities|Capabilities]] — the window/socket owner checks the grant words generalize.
- [[evidence|Evidence & testing]] — the two-class gate discipline behind every claim above.
