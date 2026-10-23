> ARCHIVED 2026-10-23 — design record for the shipped M51 SSH client; the
> binding contract is ADR 0025. Not an active plan.

# SSH (M51) — scoping and gated card split

Status: **COMPLETE — M51 done 2026-09-12 (all eight cards merged:
SSH-P1/P2 + SSH1–SSH5; ADR 0025 accepted)** · Date: 2026-09-12 · Milestone
**M51** (goal **#1066**
Stage 3) · Umbrella **#1164** · Design card **#1165** (SSH0) · Depends on:
the M46 remote seam (ADR 0022, `--net` + `--net-tcp-respond`), the M47
primitives (ADR 0023, `user/src/lib/crypto/`), the M50 secret store and
delegated auth (ADR 0024 D6/D7/D8), ADR 0007 (syscall ABI), and the
`netauth.zig` injected-seam test pattern.

> This document is the milestone's build order. It says what each card
> delivers, how it is verified, and what is deliberately **not** here. The
> binding design decisions are in **ADR 0025**; this document does not
> restate them, it applies them.

## The one-line pitch

A guest SSH-2 **client** — `SSH.BIN` — dials **out** to a host, proves the
server's `ssh-ed25519` host key against a pinned share file, authenticates
with an Ed25519 `publickey` signature using a seed from the M50 secret
store, and drives an encrypted `chacha20-poly1305@openssh.com` channel that
runs a remote command or an interactive shell. The kernel gains exactly one
syscall (an entropy read) and stays crypto-free; a userland stream adapter
turns the bounded, reassembly-free TCP seam into a real packet stream.

## Why now, and why this shape

- **Goal #1066 names Stage 3 = SSH, and the prerequisites just landed.**
  M46 built the net front-end; M47 shipped SHA-256/512 + HMAC, ChaCha20,
  Poly1305, X25519, and Ed25519; M50 built the secret store and proved that
  crypto verification is delegated to userland. SSH is now assembly work on
  proven primitives instead of a crypto project.
- **"Get out" is more useful and more testable than "get in".** A client
  needs no host→guest forward; the runner's `--net` emulation already has a
  deterministic host TCP peer. A server needs a port-forward story that does
  not exist (ADR 0025 D1).
- **The kernel seam is the hard part, and it is not changed.** The SSH
  binary packet is variable-length; the kernel RX is one 192-byte slot with
  no reassembly. The milestone's centre of gravity is therefore the userland
  packet/stream layer (SSH1), not a kernel rewrite (ADR 0025 D6).
- **Honesty over theatre.** `curve25519-sha256` + `ssh-ed25519` +
  `chacha20-poly1305@openssh.com` + `publickey` is a real, interoperable
  profile; the missing OpenSSH cipher is an explicit prerequisite card, not
  an assumption; and the gate is client-side because that is what the VZ NAT
  can actually prove.

## Protocol profile (ADR 0025 D2)

| Role | Offered (M51 only) | Shipped primitive |
|---|---|---|
| Transport | SSH-2.0 (RFC 4253) | — |
| KEX | `curve25519-sha256` (RFC 8731) + `curve25519-sha256@libssh.org` | `x25519.scalarmult` + `sha256` |
| Host key | `ssh-ed25519` (RFC 8709) | `ed25519.verify` |
| Cipher | `chacha20-poly1305@openssh.com` | new (SSH-P2), on `chacha20`/`poly1305`/`ct` |
| MAC | none (AEAD) | — |
| Compression | `none` | — |
| User auth | `publickey`, `ssh-ed25519` (RFC 4252 §7) | `ed25519.sign` |

**Missing primitive (prerequisite, not assumption):** the OpenSSH cipher is
the original djb ChaCha20 (64-bit nonce = packet sequence number, 64-bit
counter) with a split 64-byte key and Encrypt-then-MAC over
`enc_length ‖ enc_payload`. The RFC 8439 `crypto/aead.zig` and the 12-byte
nonce `crypto/chacha20.zig` **cannot** be used. SSH-P2 adds
`crypto/chacha20_ssh.zig` + `crypto/ssh_cipher.zig`, pinned to the OpenSSH
`PROTOCOL.chacha20poly1305` vector. (The IETF draft names K_1/K_2 inverted
from the OpenSSH file — implement to the OpenSSH file.)

## Hard constraints (stated, scoped around)

1. **The kernel TCP seam is single-connection, bounded, and has no
   reassembly.** `payload_max = 192`, `segment_max = 212`,
   `frame_max = 246` (`kernel/src/tcp.zig:63-67`); an oversized RX payload is
   dropped (`:634`); a segment arriving while the one-slot RX buffer is full
   is dropped **and not ACKed** (`:765`). `sys_tcp_recv` (slot 32) returns at
   most one ≤192-byte chunk. This makes the **userland stream adapter /
   packet layer (SSH1) mandatory**: it reassembles SSH packets across chunks,
   drains the slot promptly, paces TX to one outstanding segment, and fails
   closed on overflow. Correctness under a dropped segment leans on the
   peer's TCP retransmission, and the throughput ceiling is
   segment-at-a-time — both stated, not hidden. No kernel RX ring in M51.
2. **No kernel crypto imports (ADR 0023 D2).** SSH lives in userland on the
   M47 primitives; the kernel only returns entropy bytes and moves TCP bytes.
   There is no kernel `sha256`/`ed25519`/`chacha` call anywhere in this
   milestone.
3. **One syscall slot at most per card.** The only new slot is SSH-P1's
   `sys_getrandom` (slot 72; `implemented_count` 72 → 73). Every other card
   adds zero. The delegated-auth / secret-store patterns are reused rather
   than inventing kernel surface: `sys_secret_get` (slot 70) supplies the
   key, the file ABI supplies the public pins.
4. **Spec-first gates (AGENTS.md M40 GF6).** Class A for the protocol/state
   machines (pure, injected seams like `user/src/lib/netauth.zig`); class B
   is a declarative `tools/gate/specs/live-ssh-*.spec`, discovered by
   `tools/gate/fleet.sh`, never a one-off shell script.
5. **Boot default unchanged is a must-observe.** No SSH code on the boot
   path; `sys_getrandom` registered but not called at boot; nothing listens
   and nothing dials unless a process asks; the existing class-B fleet stays
   green.

## Layout (expected files; a card may adjust within its scope)

```
user/src/lib/ssh/wire.zig          NEW  SSH byte/string/mpint/name-list codec (SSH1)
user/src/lib/ssh/packet.zig        NEW  RFC 4253 binary packet framing (SSH1)
user/src/lib/ssh/stream.zig        NEW  stream adapter over sys_tcp_* (SSH1)
user/src/lib/ssh/kex.zig           NEW  version/KEXINIT/curve25519-sha256/NEWKEYS (SSH2)
user/src/lib/ssh/transport.zig     NEW  encrypted RFC 4253 packet transport over the AEAD (SSH4)
user/src/lib/ssh/userauth.zig      NEW  none probe + publickey ed25519 (SSH3)
user/src/lib/ssh/channel.zig       NEW  session/pty/exec channels (SSH4)
user/src/lib/ssh/cli.zig           NEW  pure [user@]host[:port] [cmd] grammar (SSH4)
user/src/ssh.zig                   NEW  SSH.BIN app + CLI (SSH4)
user/src/lib/rng.zig               NEW  sys_getrandom wrapper (SSH-P1)
user/src/lib/crypto/chacha20_ssh.zig  NEW  djb ChaCha20, 64-bit nonce/counter (SSH-P2)
user/src/lib/crypto/ssh_cipher.zig    NEW  chacha20-poly1305@openssh.com (SSH-P2)
kernel/src/syscall.zig             slot 72 sys_getrandom (SSH-P1)
host/vm-runner/Sources/VMRunner/main.swift  --net-tcp-respond …:ssh (SSH5)
tools/gate/specs/live-ssh-*.spec   NEW  class-B fleet (SSH5)
SSH/KNOWN_HOSTS (share)            host-seeded pins (SSH3/SSH5)
SECRETS.TXT (share)               ssh-user-ed25519 seed, uid 1000 (SSH3/SSH5)
```

The SSH library is a sibling of `netauth.zig` — the M50 delegated-auth
verifier the guest runs when it *hosts* the remote door. The two share the
crypto library and the OS seams, not the protocol or the direction.

## Card split and acceptance

| Card | Deliverable | Class-A acceptance | Class-B acceptance | Boot default |
|---|---|---|---|---|
| **SSH0** #1165 (this doc) | ADR 0025 + this scoping doc, docs-only PR | docs review; no code | none | unchanged |
| **SSH-P1** #1166 | `sys_getrandom(buf, len)` slot 72; `lib/rng.zig`; ADR 0007 table + count 72→73 | bounded length (cap; `len==0`→0; `EFAULT` bad buffer), no capability, table/count pinned; no boot-path call | a probe (or SSH2's fresh-key proof) shows entropy reaches EL0; fleet green | slot registered, never called at boot |
| **SSH-P2** #1167 | `crypto/chacha20_ssh.zig` (djb, 64-bit nonce/counter) + `crypto/ssh_cipher.zig`; OpenSSH construction | OpenSSH `PROTOCOL.chacha20poly1305` vector (Poly key `76b8e0ad…`); seal/open round trip; tag tamper reject via `ct.ctEq`; sequence-number nonce advances | none (crypto KAT is class-A); fleet green | no code on boot path |
| **SSH1** #1168 | `ssh/wire.zig`, `ssh/packet.zig`, `ssh/stream.zig` | wire round-trips (byte/uint32/uint64/string/mpint/name-list); packet length/padding bounds; split-packet reassembly; ring-overflow **fail-closed**; one-outstanding-segment TX pacing — all over an injected seam | a deterministic responder sends a known packet split across many segments; the guest reassembles and echoes a digest | untouched |
| **SSH2** #1169 | `ssh/kex.zig`: version exchange, KEXINIT, `curve25519-sha256`, `ssh-ed25519` host-key verify, exchange hash `H`, KDF, NEWKEYS, cipher install | pinned RFC 8731/4253 KEX vectors; wrong host-key sig / tampered `H` / wrong `session_id` rejected; derived keys match the KDF | covered by SSH5's positive run | untouched |
| **SSH3** #1170 | `ssh/userauth.zig`: service request, `none` probe, `publickey` ed25519 signature; `SSH/KNOWN_HOSTS` parser; TS5 `ssh-user-ed25519` read + `ct.wipe` | signature over `session_id ‖ request` verifies; wrong key refused; `none`→`publickey` flow; missing key/pin fails closed with a distinct status; secret never logged | covered by SSH5's positive/negative runs | no secret read at boot |
| **SSH4** #1171 | `ssh/transport.zig` (encrypted packet transport over `kex.Result`), `ssh/channel.zig`, `ssh/cli.zig` + `user/src/ssh.zig` (`SSH.BIN`): session open, `pty-req`/`shell` or `exec`, data/window/EOF/close; CLI `SSH.BIN [user@]host[:port] [cmd]` | channel state machine, window accounting, EOF/close, exec-vs-pty dispatch; no-rekey byte/packet bound disconnects; sealed/open transport round trip + tamper fail-closed; sequence continuation across NEWKEYS | SSH5 drives a one-shot `exec` marker and an interactive shell line | untouched |
| **SSH5** #1172 | runner `--net-tcp-respond …:ssh` minimal SSH server (pinned host key + pinned publickey + one exec); `tools/gate/specs/live-ssh-*.spec`; inventory regenerated | — (gate card) | positive KEX+auth+exec; unknown host key refused; wrong user key refused; tampered MAC disconnected; missing credential fail-closed; `serial-absent '[EXC]'` | fleet re-run green |
Each implementation PR updates ADR 0007's table and `implemented_count` where
it adds a slot (only SSH-P1), regenerates `docs/gate-fleet-inventory.md` when
it adds a spec (SSH5), and presents `boot-default-unchanged` evidence.

### SSH4 implementation notes (the decisions SSH5's gate targets)

- **Encrypted transport landed** in `user/src/lib/ssh/transport.zig` (the
  piece SSH3 deferred): RFC 4253 §6 framing + the OpenSSH AEAD wire shape
  `enc_length(4) ‖ enc_payload ‖ tag(16)`, `decryptLength` first, tag
  verified before use, and the cipher sequence numbers **continuing across
  NEWKEYS** (never reset).
- **No-rekey bound**: 1 GiB or 2^20 packets per direction, whichever comes
  first; reaching it sends `SSH_MSG_DISCONNECT` (reason 11
  `BY_APPLICATION`) and closes. A DISCONNECT from either side ends cleanly.
- **Interactive `shell` local input is LANDED with no new kernel surface.**
  The question "where does the local keyboard come from" is answered with
  the existing `/dev/tty` file ABI (slots 23/24/26) plus slot 67's serial
  attach — the same seam `SH.BIN` uses — with the raw byte queue pumped as
  `CHANNEL_DATA`; the remote pty echoes. If no terminal can be attached,
  `SSH.BIN` fails closed with `stage=tty` / exit 10. The acceptance-critical
  path remains the one-shot `exec` (and is what SSH5's positive run drives
  first).
- **Hostnames/DNS are a documented later slice.** SSH4 resolves only a
  numeric IPv4 literal; `host.example` fails usage (exit 1) instead of
  guessing. The KNOWN_HOSTS `#v1` key stays the literal host text the user
  typed, matching the M50 pin format.
- **`SSH.BIN` exit statuses** (distinct per failure stage): 0 remote/success
  (or the remote `exit-status`), 1 usage, 2 connect, 3 kex, 4 host pin,
  5 auth, 6 channel, 7 request, 8 transport/protocol, 9 no-rekey bound,
  10 no tty, 255 remote `exec` sent no `exit-status`.

### SSH5 implementation notes (the endpoint gate, and what it caught)

- **Runner-hosted responder**: `host/vm-runner/Sources/VSSH/` (a
  Virtualization-free Swift library) implements the minimal SSH-2 server:
  version exchange, one-suite KEXINIT, `curve25519-sha256` (CryptoKit
  X25519), a pinned `ssh-ed25519` host key, the RFC 4253 §7.2 KDF, NEWKEYS,
  the OpenSSH AEAD, `publickey` verification against a pinned client key,
  one `session` channel, and one fixed `exec` (marker + `exit-status`).
  `VMRunner` gains `--net-tcp-respond <ip>:<port>:ssh` plus
  `--net-tcp-respond-ssh-hostkey/-userkey/-tamper-mac/-marker/-exit`; TX is
  paced **one encrypted ≤192-byte segment per guest ACK**, the `:packet`
  mechanism.
- **Cipher drift guard**: the Swift cipher is **hand-rolled** (djb ChaCha20
  with the 64-bit nonce/counter, Poly1305, the OpenSSH split-key Encrypt-
  then-MAC). It is tied to SSH-P2 by the same pinned vectors: a startup
  self-check refuses to arm `:ssh` unless the OpenSSH
  `PROTOCOL.chacha20poly1305` vector reproduces (`cipher self-check ok`),
  and `swift test` pins that vector plus the RFC 8439 ChaCha20/Poly1305
  vectors and `kex.zig`'s deterministic transcript (X25519 K, H, the KDF
  C2S/S2C keys, and verification of the OpenSSL-pinned host signature).
  CryptoKit Ed25519 signs with a hedged nonce (two signatures differ per
  call — observed), so the host-key tie is verification, not byte equality.
- **The gate caught two latent SSH4 wire bugs, fixed here**: SSH3's
  `publickey` request sent the signed `string session_id` prefix **on the
  wire** (RFC 4252 §7 signs it but the packet starts at
  `SSH_MSG_USERAUTH_REQUEST`), and the channel layer expected a 1-byte
  `CHANNEL_EOF` instead of the RFC 4254 §5.3 `uint32 recipient` form. Both
  were invisible to the class-A scripted peers (they pinned the same wrong
  layouts); the end-to-end endpoint gate exposed them, and the class-A
  vectors were re-pinned to the corrected bytes.
- **Live class-B results (2026-09-12, Apple silicon VZ)**:
  `live-ssh-endpoint` PASS 1/1 (guest `kex-ok` → `pin-ok` →
  `auth-ok method=publickey` → `channel-open remote=42` →
  `VIRELAI-SSH5-OK` → `exit-status=0` → `eof` → `bye rc=0`; responder log
  shows KEX, `publickey accepted`, and the exec; the seed never appears in
  either log); `live-ssh-negative` PASS 3/3 (unknown pin → `stage=auth rc=4`
  with **no** service request observed server-side; wrong user key →
  `AuthRejected rc=5`; tampered first server tag → `stage=protocol rc=8`);
  `live-ssh-nocred` PASS 1/1 (`MissingCredential rc=5`). No TX clobbering
  was observed in these runs (all multi-segment KEXINIT/ECDH/NEWKEYS/RESP
  segments arrived; no retransmission was needed), but that remains the
  documented best-effort limit below — the ABI still has no `tx_pending`
  read.
- **Real-OpenSSH interop (issue #1209, 2026-09-12): transport proved, one
  conformance gap observed.** The SSH5 attempt had stopped at the network
  leg; #1209 first proved that blocker is real and not a
  bind/firewall mistake: under `--net-nat` the guest resolves and pings
  the 192.168.64.1 gateway, but while the VM ran no host interface carried
  the guest subnet (`vmenet0` inactive, no address), there was no host
  route or ARP entry for 192.168.64.0/24, the gateway MAC is synthetic
  (a Virtualization.framework-internal router), the macOS application
  firewall was OFF, and `sshd` bound `*:2222` (DEBUG3) logged **nothing**
  while both `SSH.BIN` and the monitor's own `net tcp connect` sat in
  SYN_SENT. The run then used a new **byte-transparent runner relay**
  (`--net-tcp-respond <ip>:<port>:relay` +
  `--net-tcp-respond-relay 127.0.0.1:2222`; no crypto in the runner)
  against the host's real `/usr/sbin/sshd` (OpenSSH_10.3p1, LibreSSL
  3.3.6), generated host key pinned in `SSH/KNOWN_HOSTS`, RFC 8032 TEST 2
  client key in `authorized_keys`, fixed command `echo
  VIRELAI-INTEROP-OK`. Observed: KEX negotiated `curve25519-sha256` +
  `ssh-ed25519` + `chacha20-poly1305@openssh.com` (no compression) and the
  client verified the real host-key signature (`ssh: kex-ok`); real sshd
  then rejected the first encrypted packet with `padding error: need 28
  block 8 mod 4`, `SSH2_MSG_DISCONNECT: Packet corrupt`, and `message
  authentication code incorrect`. Root cause: OpenSSH pads
  `chacha20-poly1305` so `packet_length` (the encrypted part after the
  4-byte length) is block-aligned, while the client and VSSH aligned
  `4 + packet_length`; the plaintext KEX path uses the other rule, which
  is why KEX completed. Userauth/exec stdout/`exit-status` were NOT
  observed; the seed never appears in any log. Fix: follow-up **#1210**
  (client + VSSH realignment), not smuggled into the evidence change.
  Raw evidence: `artifacts/m51-interop/`.
- **Real-OpenSSH interop FIXED (claim #1210, 2026-09-12): observed end to
  end.** The AEAD padding now follows the cipher (`packet.Alignment`):
  `.aead` aligns `packet_length` alone for the post-NEWKEYS
  `chacha20-poly1305` path, `.plaintext` keeps `4 + packet_length` for KEX,
  and VSSH mirrors it (its startup drift guard also pins the OpenSSH
  `packet_length = 0x48` frame). Re-running the same relay against real
  OpenSSH 10.3 then exposed **two more real-server conformance bugs**, both
  fixed with class-A vectors: `channel.open()` rejected OpenSSH's
  pre-confirmation `hostkeys-00@openssh.com` GLOBAL_REQUEST (which carries a
  request-specific host-key blob — RFC 4254 §4 says ignore it) and treated
  sender channel id **0** as "unset". Observed in
  `artifacts/m51-interop/runs/relay-06/` (serial + sshd DEBUG3 + runner
  stdout; seed absent everywhere): `SSH.BIN tbuddy@10.0.0.2:2222 echo
  VIRELAI-INTEROP-OK` completed `kex-ok`, `pin-ok`, `auth-ok
  method=publickey`, `channel-open remote=0`, the remote stdout
  `VIRELAI-INTEROP-OK`, `eof`, `exit-status=0`, `bye rc=0`.

**Coordination with #1163 (GOOS=virelai port).** `sys_getrandom` is a single
shared contract, not two: **slot 72 is owned by SSH-P1 (#1166)** and the Go
runtime consumes it — if the Go port lands first it implements slot 72 to
this contract and SSH-P1 becomes the thin `lib/rng.zig` wrapper. The Go
port's `thread_create`/`futex` append at 73/74. The Go port's ADR takes
**0026** (SSH0 keeps 0025). Neither claim re-adds an entropy syscall; see
#1163 for the reciprocal note.

## Implementation order

```
SSH0 (design) ──┬──► SSH1 (packet/stream) ──────┐
                ├──► SSH-P1 (entropy, slot 72) ──┼──► SSH2 ──► SSH3 ──► SSH4 ──► SSH5
                └──► SSH-P2 (OpenSSH cipher) ───┘
                (independent, any order)          (KEX)     (auth)    (SSH.BIN) (gate)
```

- **SSH0 first** — this docs PR; it freezes the suite, the stores, and the
  boundary so no later card re-litigates them.
- **SSH1, SSH-P1, SSH-P2 are independent** after SSH0 and may land in any
  order (SSH1 is the largest; the two prerequisites are small and unblock
  SSH2).
- **SSH2 needs all three**, because KEX both flows through the adapter and
  consumes entropy and the cipher.
- **SSH3 then SSH4** — userauth before channels; `SSH.BIN` is the first
  user-visible payoff.
- **SSH5 last** — the endpoint gate exercises the whole stack, so it lands
  once the client is complete; negative runs are written alongside.

If a single session cannot land the whole milestone, the umbrella rule
applies: land the smallest complete slice with its gate (SSH-P1 + SSH1 with
class-A proof) and leave the rest on the tracker — the cards exist as
#1166–#1172.

## Threat model

**Protected:** the SSH session's **confidentiality and integrity** after
NEWKEYS (AEAD over every packet); **server authentication** to a pinned
`ssh-ed25519` host key (a changed key is refused, not warned); **client-key
confidentiality** (the Ed25519 seed lives in the file-ABI-denied secret
class, is read only through `sys_secret_get`, and is wiped after use);
**freshness** (ephemeral X25519 keys + `session_id` make a captured session
non-replayable); the kernel stays out of the crypto trust base.

**Not protected, by decision:** the M50 inbound remote door (plaintext,
unchanged by M51); the **server** direction (does not exist yet); a
compromised host or a malicious pinned key (a pin is trust, not proof);
availability (the segment-at-a-time adapter is slow and there is no
rate-limit/rekey); password/keyboard-interactive auth (not offered); a
side-channel-proof implementation (ADR 0023 D3's stated limit); and
multi-user isolation beyond TS5 `uid` scoping.

## Non-goals (explicit)

- **No SSH server, no listener, no port forward** (ADR 0025 D1).
- **No kernel crypto import and no kernel TCP rewrite** (ADR 0025 D4/D6).
- **No TLS** (ADR 0024 D7 stands); SSH is the session-encryption card.
- **No RSA/ECDSA/DSA, no AES-GCM/CTR, no bignum** — the suite is exactly
  the table above.
- **No password / keyboard-interactive / agent / forwarding / SCP / SFTP /
  X11 / certificates.**
- **No rekey in M51** (bounded reconnect instead).
- **No `sys_secret_set`** — provisioning stays host edits the share file.
- **No new syscall slot beyond slot 72.**

## Risks / open questions

- **The one-slot RX drop is the sharp edge.** Correctness rests on the peer
  retransmitting the un-ACKed dropped segment; the adapter must drain
  promptly and the gate responder must pace. If a real server floods
  back-to-back segments, throughput collapses to the RTO — stated, and the
  driver for the deferred kernel RX ring.
- **The kernel does not validate RX sequence numbers.** The adapter assumes
  the peer's in-order TCP guarantee; a hostile peer could desynchronize the
  stream. Fail-closed parsing bounds the damage, but it is an assumption.
- **Swift responder ↔ Zig client cipher drift — closed, pinned.** The
  hand-rolled Swift cipher is asserted against the same OpenSSH/ChaCha20/
  Poly1305 vectors and the `kex.zig` transcript at both `swift test` time
  and at `:ssh` startup (`cipher self-check ok`); the custom-virtio fallback
  was not needed. CryptoKit Ed25519's hedged nonce means signatures are
  verified, not byte-pinned.
- **Ephemeral key entropy is a new kernel surface.** Slot 72 is small and
  ownerless by design; SSH-P1 must prove it cannot be called on the boot
  path and does not weaken the CSRNG (it only reads it).
- **Real-OpenSSH interop: CLOSED by #1210 (2026-09-12).** The honesty run
  (#1209) surfaced three conformance gaps that only a real server could —
  the AEAD `packet_length` alignment, the pre-confirmation
  `hostkeys-00@openssh.com` GLOBAL_REQUEST (with trailing request data), and
  sender channel id 0 — all fixed and observed end to end against real
  OpenSSH 10.3 (`artifacts/m51-interop/runs/relay-06/`: KEX, userauth,
  remote stdout, `exit-status`, EOF, clean close; seed absent from every
  log). VZ-NAT guest→host TCP remains a confirmed dead end on this host (no
  host interface/route/ARP for the guest subnet, synthetic gateway,
  firewall off, sshd saw nothing), so the run goes through the
  byte-transparent runner relay. The predicted gaps list shrinks to window
  sizes and the exact rekey/`mpint` behaviours, all still unobserved
  against a real server.
- **The guest's multi-segment TX is best-effort (SSH1's documented limit).**
  The ABI has no `tx_pending` read, so the adapter cannot wait for an ACK
  between segments; the kernel's retransmit buffer holds one segment and a
  loss on a real link can outrun it. No TX clobbering was observed across
  the five SSH5 live runs (all KEX segments arrived without retransmission),
  but this is the recorded driver for a future `tx_pending`/RX-ring
  amendment if a real link ever exposes it.
- **Key provisioning UX.** Two host-edited files (`SECRETS.TXT`,
  `SSH/KNOWN_HOSTS`) with no in-guest setter; the human must hex-encode keys.
  A future card may add a provisioning helper or OpenSSH-format import.
