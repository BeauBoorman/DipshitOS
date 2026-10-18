# ADR 0056: The guest→host control channel — `virelai-ctl/1` over virtio-vsock

- Date: 2026-10-18
- Status: **Proposed** — lands with this PR; the wire is live-verified by
  `live-vsock-ctl`, the verbs are refused by name until M115d/e arm them.
- Card: **#2461** (M115, index #2448) — card 2 of 7; depends on M115a
  (#2460), gates M115d (#2463) and M115e (#2464).
- Related: ADR 0044 (the agent control channel — same handshake shape,
  inverted direction), ADR 0051 (the VHI1 file lane — same fail-closed
  refusal vocabulary), ADR 0024 D8 (the secret class the credential
  lives in), `docs/hardware-contract.md` (the M115a verdict this ADR
  rides on).

> M115a observed that `VZVirtioSocketDevice` is the only in-SDK
> guest↔host channel that passes `validateSaveRestoreSupport` — every
> custom-virtio attachment is refused `VZErrorDomain` Code=2, so nothing
> riding the file channel can survive the suspend/snapshot cycle this
> arc exists to drive. This ADR pins the control channel that runs on
> it: a guest-initiated stream connect to a dedicated host port, one
> HMAC challenge, then newline-delimited verb requests. Fail-closed at
> both ends: no credential, no service.

## Mission

Pin the wire — transport, framing, auth, verbs, refusal names — and
land the minimal both-sides implementation: a kernel ctl client driven
by the `vsock ctl` monitor command, a pure-Go protocol package
(`user/go/vsockctl`) for the EL0 callers M115d/e will bring, and the
host endpoint (`VSCtl` + `VSockCtl.swift`) behind `--vsock-ctl`. Out of
scope: acting on the verbs (M115d/e), an EL0 binding (D5), profiles
(M115c), live migration.

## Grounding (observed in tree `e8b4f887`, 2026-10-18)

- **The device and the probe work.** `kernel/src/virtio_vsock.zig`
  enumerates DID `0x1053`, arms rx/tx/event rings, and `connect()`
  issues one stream `OP_REQUEST` per `vsock <port>`; the runner arms a
  `VZVirtioSocketListener` on `--vsock-port` (default 1208) and accepts
  under `--vsock`. `vsock 1208` → `VSOCK: listener accepted`; `vsock 9`
  → peer RST. Recorded in `docs/hardware-contract.md` and pinned by
  `live-vsock-restore`.
- **An accepted connection is an fd.** `VZVirtioSocketConnection`
  owns a `fileDescriptor` the host reads and writes directly — the
  endpoint needs no framing beyond "bytes in, bytes out".
- **The auth shape exists twice already.** ADR 0024 D6/D7's
  `VIRELAIOS-AUTH/1` and ADR 0044 D2's `virelai-agent/1` are the same
  HMAC-SHA256 challenge: server mints 32 random bytes, client answers
  `HMAC(key, domain || 0x00 || challenge)`, a per-scheme domain string
  makes captures non-portable between services. Both ends have the
  primitive: `shlib.HMACSHA256` in Go, CryptoKit on the host, and
  `measure.Sha256` in the kernel (HMAC is 20 lines on top).
- **The credential rides the share.** `SECRETS.TXT`
  `key<TAB>uid<TAB>value[<TAB>apps]` rows load into the slot-70 store
  at boot (`secret.init_from_share`); the runner reads the same file
  off the armed `--cvc-file` directory — the M108 double-reader
  pattern (`HostInt.readSecret`). No new provisioning channel.
- **The monitor is the only in-guest vsock caller.** There is no EL0
  door to the transport: the slot-80 socket ABI is TCP/UDP, and every
  path a new syscall would touch (`kernel/src/syscall.zig`, the ADR
  0007 slot table, `kernel/tests/syscall_test.zig`, `user/go/vi/`) is
  under live claims this cycle (M116b #2468, M118c #2481). The v1
  initiator is therefore EL1h — the `vsock ctl` monitor command — and
  the EL0 binding is a named follow-up (D5).
- **Secret values stay out of the monitor's hands for EL0 files** —
  `kernel_vf_allowed` denies secret-class paths to *every* actor, so a
  kernel ctl client cannot `vf cat SECRETS.TXT`. It doesn't need to:
  `secret.records_for` is the kernel's own store, and a `uid 0`
  (`uid_system`) row with no `apps` binding is visible to a
  `uid_system` reader and no `uid_user` process.
- **Verbs are requests, not actions.** M115d owns `suspend` (fsync,
  marker, save); M115e owns `snapshot <name>`. This card proves the
  channel carries them end to end.

## D1. Transport and framing

- **Endpoint.** Guest issues one stream connect to
  `VMADDR_CID_HOST:<ctl-port>` where ctl-port is the runner's
  `--vsock-ctl-port` (default **1209**, distinct from the M115a probe
  listener on 1208 — the probe keeps its accept-and-log semantics).
  Armed only under `--vsock --vsock-ctl`; `--vsock-ctl` without
  `--vsock` is a runner arg error.
- **Framing.** One UTF-8 JSON object per line, LF-terminated (the ADR
  0044 shape — a server greeting, then client lines, one reply line
  per request, in order). Limits: **256 bytes pre-auth**, **1024 bytes
  per line post-auth**, counting the LF. A line over its cap is
  `line_too_long` (fatal); a line that is not one JSON object is
  `bad_json`; a well-formed object with missing/mistyped/unknown keys
  is `bad_request`. `null`, arrays, nested objects and duplicate keys
  are `bad_request` — the grammar is flat, both parsers are 100-line
  hand-rolled jobs (the kernel must parse too; `encoding/json` never
  enters the guest, ADR 0042 §1).
- **Session.** One connection = one auth, then requests until close or
  a fatal code. Requests carry `id`, a u32 that must be **1 on the
  first request and +1 on each later one** — a repeated or skipped id
  is refused `replay` (non-fatal). The guest hangs up with
  `OP_SHUTDOWN` both-ways; an unanswered `OP_RST` or a peer RST ends
  it. 10 s to complete auth, 60 s idle ceiling; both fatal.
- **Cardinality.** The host accepts at most 4 concurrent ctl sessions;
  the guest side serializes itself (one monitor command at a time).

## D2. Trust and auth — fail closed

**Who may connect:** a guest holding the `vsock-ctl` secret row, on a
listener the operator armed with `--vsock-ctl`. The channel can ask
the host to suspend or snapshot the whole machine, so the bar is the
agentd bar: credential required, no open mode, refusals named.

**Provisioning:** `SECRETS.TXT` carries
`vsock-ctl<TAB>0<TAB><value>` — a `uid_system` row with no app binding.
It is deliberately *not* `uid_user`: no EL0 principal holds uid 0, so
the row is invisible to every `sys_secret_get` caller while remaining
readable by the kernel's own ctl client (`secret.records_for` with the
`uid_system` reader). This is not a new reader of the store — slot 70
is still the only *in-guest* EL0 reader — it is the kernel consuming a
system credential it already loads. The runner reads the same row off
the share directory (`HostInt.readSecret`'s `key/uid/value` line
grammar, uid `0`). Value bytes are the key verbatim, ≤ 64 bytes.

**Posture order.** Any failure names itself and serves nothing:

- Runner: `--vsock-ctl` + no armed share, or no `vsock-ctl` row →
  `VSOCK-CTL: refuse no_credential`, no listener (a guest connect gets
  the honest RST the unlistened port already produces).
- Guest: `vsock ctl` with no device → `vsock-ctl: refuse no_device`;
  no row → `vsock-ctl: refuse no_credential`; connect verdicts are
  `vsock-ctl: connect refused|timeout`.

**Handshake** (one attempt per connection):

```
S: {"proto":"virelai-ctl/1","auth":"hmac-sha256","challenge":"<64 hex>"}
C: {"auth":"<64 lowercase hex>"}
S: {"ok":true,"session":"ready","verbs":["suspend","snapshot"]}
```

- The challenge is 32 fresh bytes per connection (host CSPRNG).
- MAC = `HMAC-SHA256(key, "VIRELAI-CTL/1 hmac-sha256" || 0x00 ||
  challenge[32])` — a domain distinct from `VIRELAIOS-AUTH/1` and
  `VIRELAI-AGENT/1`, so a MAC captured from GOSH's net auth or AGENTD
  can never answer this server, and a captured `virelai-ctl/1` answer
  dies with its connection's challenge.
- Refusals, each session-fatal after one error line: `auth_required`
  (a `verb`/`id` key in the first line), `auth_failed` (bad hex or MAC
  mismatch — a replayed answer is simply a MAC against the wrong
  challenge), `auth_timeout` (10 s). The listener does not dampen
  re-listen the way agentd does (the kernel client is the only driver)
  but a failed session still closes.
- Pinned vector (class A, all three ends): key = ASCII `a5` × 32 (64
  bytes), challenge = `00 01 … 1f`, MAC =
  `87b459ff70564dd354e1415d16618cc768bf5f2181124a2b495c73b01e274b6c`.
- The never-logged contract holds: keys, challenges, MACs and request
  payloads never reach serial or runner stdout — markers carry
  `id=`/`code=`/port numbers only.

## D3. Verbs and replies

| Verb | Args | Means | M115b answer |
|---|---|---|---|
| `suspend` | none | fsync the guest, request a VZ save of this VM | `unimplemented` |
| `snapshot` | `name`: NAME | park a named snapshot on the share | `unimplemented` |

`NAME` is the ADR 0044 grammar verbatim: 1–31 bytes of
`[A-Za-z0-9._-]`, first byte alphanumeric, never `.`/`..`; a bad one is
`name_rejected`. Both verbs are *understood* this card and *refused by
name* until M115d/e arm them — `unimplemented` is the honest positive
leg of `live-vsock-ctl`: the request line arrived, parsed,
authenticated, and was answered by name. Success replies are
`{"id":N,"ok":true,"result":{…}}` for the landing cards to fill.

## D4. Refusal names (complete)

| Code | When | Fatal |
|---|---|---|
| `bad_json` | line is not one JSON object | no |
| `bad_request` | missing/unknown/duplicate/mistyped field, `null`/nested/array value, `id` out of range | no |
| `unknown_verb` | `verb` not in D3 | no |
| `name_rejected` | `snapshot` name fails the NAME grammar | no |
| `replay` | `id` is not exactly last+1 | no |
| `unimplemented` | verb is wired, action deferred (M115d/e) | no |
| `io_error` | transport-level failure mid-session | yes |
| `auth_required` / `auth_failed` / `auth_timeout` | D2 | yes |
| `line_too_long` | line over its cap | yes |
| `idle_timeout` | 60 s without a request | yes |

## D5. The initiator is EL1h this card — the EL0 binding is a follow-up

The only in-guest caller of the transport is the kernel monitor:
`vsock ctl <verb>` runs connect → greeting → HMAC answer → request →
reply → shutdown as one command, printing `vsock-ctl:` markers the
gate asserts. Three scripted exercise modes cover the negatives
without host-side hooks: `vsock ctl badauth <verb>` sends a corrupted
MAC, `vsock ctl replay <verb>` replays a captured auth line verbatim
on a fresh connection (the new challenge makes it `auth_failed`), and
`vsock ctl dup <verb>` repeats request id 1 inside one session
(`replay`).

`user/go/vsockctl` is the same protocol in Go — greeting parse, auth
answer, request encode, reply parse, the refusal names — as a pure
package over an injected transport, so the class-A tests pin the wire
and the seat (M115d) binds a real one the day the ABI slot exists.
**That slot is deliberately not this card:** a `sys_vsock_ctl` row is
an ADR 0007 amendment touching `kernel/src/syscall.zig`, the ADR 0007
file and `user/go/vi/` — all three under live claims this cycle
(#2468, #2481). The coordination gate, not the design, sets the timing;
the ADR records it so M115d files the slot card first rather than
discovering the wall mid-card.

## D6. Out of scope / does not change

- Acting on `suspend`/`snapshot` (M115d/e), the `.virelaivm` profile
  (M115c), `GOSNAP.ELF`, self-update staging, live migration.
- Post-auth confidentiality/integrity, server authentication,
  encryption — same posture as ADR 0024 D7/0044 D2's plaintext session.
- The M115a probe (`vsock <port>`, port 1208 listener) keeps its
  verdicts untouched; `live-vsock-restore` is unchanged.
- The boot default: nothing attaches `--vsock`/`--vsock-ctl` but the
  specs that ask for it.

## Acceptance

- Class A: `zig build test` (virtio_vsock stream codec + vsock_ctl
  auth/request vectors), `go test ./...` (`vsockctl` pinned vectors +
  session negatives), `swift test` (`VSCtl` session state machine:
  greeting/auth/request/reply/refusal matrix, forged MACs, replay,
  id drift).
- Class B: `live-vsock-ctl` — `suspend` and `snapshot NAME` round
  trips answered `unimplemented`; `frobnicate` → `unknown_verb`;
  `badauth`/`replay`/`dup` exercise modes refused by name; the
  no-credential posture refuses the endpoint itself.
