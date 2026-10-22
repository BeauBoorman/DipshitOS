# ADR 0052: Agent identity — per-agent credentials, declared caps, revocation, audit contract

- Date: 2026-10-16
- Status: **Accepted** — the D1–D5 + D7 decision set shipped with M109
  (all six cards landed; the row's caveat — reference-host K=5 and
  owner sign-off on #2402 — is gate debt, not design debt). No code
  lands here; the D7 Touches were the arc's binding file splits.
  **Amended 2026-10-22 (card #3029, card #3029):** the D6 bullet that kept
  agent identity channel-level is superseded — the agent is the kernel
  principal `uid_agent`; see the amendment below.
- Card: **#2397** (M109, index #2382) — card 1 of 6; gates M109b–f.
- Related: ADR 0024 (D1 principals, D5 caps, D8 secrets — the trust
  baseline this builds on), ADR 0044 (the channel this identity rides;
  its "Not provided" TCP bullet is amended by D5 below), ADR 0049
  (`agent-sign` — the SCM author seed an agent's `flint commit` runs
  under), ADR 0051 (the VHI1 lane shape the audit receipts reuse),
  ADR 0007 (slot-70 secret lane; slot-80 socket ABI).

> ADR 0044 gave an outside agent one shared door key (`agent-hmac`)
> and no name: every caller of the channel was "the agent". M109 gives
> agents principals of their own. The unit of identity is a row in a
> public-key keyring file — `agent=<id> key=<pub> caps=<csv>` plus
> `revoked=<pub>` — provisioned host-side, owned `uid_system`,
> world-readable and unforgeable in-guest. The private half never
> enters the guest at all, which is strictly stronger than storing a
> shared secret in the 8-entry secret store. Caps are declared per
> agent from the `apps.txt`/`caps=` vocabulary, a missing cap is a
> named refusal, and every verb — allowed or refused — leaves a MAC'd
> receipt on the share in the M108 lane shape.

## Mission

Pin, before any verb code: the principal (credential row format,
provisioning, storage class, revocation), the cap vocabulary and the
verb→cap table, the audit contract M109c implements (receipt fields,
landing place, bounds, rotation), the concurrency answer M109d needs
(a saved `live-ssh-server` run, not a guess), and the file-level
Touches for M109b–e. Out of scope: verb code, the audit writer, the
viewer, the journey — those are cards b–e.

## Grounding (observed in tree `d0a14b6d`, 2026-10-16)

- **Today's door is one shared HMAC key.** `SECRETS.TXT` carries
  `agent-hmac<TAB>1000<TAB><value><TAB>AGENTD.ELF`; the handshake is
  `{"auth":"<64 hex>"}` = HMAC-SHA256 over
  `"VIRELAI-AGENT/1 hmac-sha256" || 0x00 || challenge`
  (`user/go/agentd/auth.go`, ADR 0044 D2). Every caller is the same
  identity; there is nothing to revoke per-agent but the whole channel.
- **The secret store cannot hold per-agent keys at any useful count.**
  `max_secret_entries = 8` (`kernel/src/secret.zig:76`), the line
  grammar is fixed `key<TAB>uid<TAB>value<TAB>apps` with no status
  field, and a full share already provisions ~7 names (`net-hmac`,
  `net-ed25519`, `ssh-user-ed25519`, `ssh-host-ed25519`, `agent-hmac`,
  `host-int`, `agent-sign`). No M109 card touches `kernel/`, so the
  bound is fixed for this arc.
- **The M101b keyring shape exists and matches the card's ask.**
  `FLINT/TRUSTED.TXT` (`user/go/flint/keyring.go`): `#v1`, rows
  `key=<64 lowercase hex Ed25519 public key> name=<label>` and
  `revoked=<64 hex>`; a malformed row refuses the whole file
  (`keyring_malformed`); revocation wins over listing and keeps the
  row, so attribution survives. Public keys are data, not secrets —
  the file lives on the share, never in the slot-70 lane.
- **Guest Ed25519 verify exists and is vector-pinned.**
  `sshlib.EdVerify` (`user/go/sshlib/ed25519.go:368`), RFC 8032 TEST
  1–3; flint signs Changes through `sshlib.EdSign`
  (`user/go/flint/sign.go:75`). GOSSHD's `SSH/AUTHORIZED_KEYS` is the
  per-principal publickey precedent (`user/go/sshlib/server.go`).
  `ed25519.go` and `x25519.go` (the shared fe51 field limbs) are the
  clean extraction unit — the rest of sshlib is the SSH stack agentd
  cannot afford on its ELF ceiling (agentd is 1,769,632 of 2,097,152
  bytes; ADR 0044's no-copy rule applies).
- **`OWNERS.TXT` can make a share file world-readable and
  unwritable-in-guest.** `AGENTS.TXT<TAB>444<TAB>0<TAB>-` reads for
  every `uid_user` process through the other bits and writes for none;
  EL0 cannot mint a `uid_system` row and cannot edit the metadata file
  (ADR 0024 M97g amendment — `OWNERS.TXT` is self-protected). The same
  `644 0 -` pattern already pins `GOSSHD.ELF`/`AGENTD.ELF` images in
  every staged spec.
- **The caps vocabulary already exists, declarative.**
  `image/apps.txt` `caps=` takes the WASM import contract's Cap names —
  `file window audio timer memory process debug net term` — so one
  word means one thing across manifests. Today nothing enforces that
  field; this ADR puts the same words to work as channel grants. ADR
  0054 (reserved for M113's grant table, claimed on #2417) may extend
  the vocabulary by amendment; until then an unknown word is malformed,
  never ignored.
- **The M108 lane shape is files on the share.** VHI1 records
  (`docs/decisions/0051-host-integration.md` D2, `user/go/hostint`):
  one record per file, `<STEM>-<seq:8hex>` names, a bounded
  outstanding count, MAC'd so a guest app that writes a lane file but
  cannot sign it gets a named refusal. The seat consumes lanes; audit
  wants persistence and an agentd producer — the *shape* carries over,
  not the tags or the directory.
- **Agentd already writes only inside `/host/AGENT/` and cannot reach
  a subdirectory through its own verbs.** `NAME` is a flat name —
  `/` in a `path` argument is `path_rejected` (ADR 0044 D3), so files
  under `AGENT/AUDIT/` are unreachable through `fs.*`. The SDK has no
  mkdir (ADR 0044 Grounding), so like `AGENT/` the directory is staged
  host-side.
- **The TCP singleton is gone.** M99f/M99g (#2184/#2185) made guest
  TCP a bounded table behind slot-80 handles: `listener_limit = 4`,
  `conn_limit = 4`, `owner_limit = 4`, `child_limit = 2`
  (`kernel/src/socket_core.zig:31-41`); a refused open is `Capacity` →
  `ENOSPC` → `vi.ErrConnBusy` (`user/go/vi/conn.go:145`). `vi.Listen`
  still mints the legacy slot-30 view agentd uses, and `vi.Dial` —
  what `flint push` calls (`user/go/flint/remote.go:60-66`) — takes an
  op-10 handle connect. Task pressure is the other bound:
  `scheduler.max_tasks` is 16 and a `GOMAXPROCS=1` Go runtime holds 3
  (the `live-ssh-server` convention).
- **Time sources for receipts.** `vi.Time()` (slot `sys_time`, wall
  seconds) and `vi.Nanos()` (monotonic CNTPCT ns) both exist.
- **Host-side Ed25519 is the thin spot.** `tools/agentctl/agentctl.py`
  is stdlib-only and Python's stdlib has no Ed25519 — the ADR 0024 D6
  note ("its class-B client story needs a host Ed25519 helper") applies
  verbatim. The wire pins the signature; the client-side mechanism is
  M109b's implementation choice (a small fresh RFC 8032 implementation
  in the harness, or a host-Go helper — `go` is on the gate host).

## D1. The principal — a row in `AGENTS.TXT`

An agent is a named credential in **`/host/AGENTS.TXT`**, the agent
keyring — the `TRUSTED.TXT` shape applied to principals:

```
#v1
agent=devin key=<64 lowercase hex Ed25519 public key> caps=file,process,window
agent=bobby key=<64 lowercase hex> caps=file
revoked=<64 lowercase hex>
```

- `agent=<id>`: 1–32 bytes from `[A-Za-z0-9._-]`, first byte
  alphanumeric — the `NAME` charset. The id is the audit label, not
  the identity; the key is.
- `key=` the agent's Ed25519 public key. The private key is generated
  and held host-side only — **no usable credential ever enters the
  guest**, which is the point the D8 secret class cannot beat.
- `caps=` the declared grants (D3). Absent or empty is a valid row:
  the agent authenticates to an empty verb set.
- `revoked=<key>` invalidates that key for new sessions. Revocation
  wins over listing — a listed-and-revoked key is revoked — and the
  rows stay, so a receipt written last month still resolves its agent
  (the M101b semantics verbatim). **One `revoked=` line is the whole
  revocation act.**
- Grammar is fail-closed whole-file, `#v1` only: a bad header, an
  unknown row shape, a bad hex, a duplicate `agent=`/`key=`/`revoked=`,
  or an unknown `caps=` word is `keyring_malformed` — a trust file is
  never half-read. Bounds: file ≤ 64 KiB (the keyring.go bound), ≤ 64
  `agent=` rows and ≤ 64 `revoked=` rows.

**Storage class.** `OWNERS.TXT` carries `AGENTS.TXT<TAB>444<TAB>0<TAB>-`:
the file is host-provisioned and host-edited (the D8 provisioning
posture — the operator owns the share), world-readable in-guest and
unwritable by any EL0 process. Because the contents are public keys,
"world-readable" costs nothing; because the row is `uid_system`-owned,
"guest-forgeable" is impossible — the M97g self-protection makes the
metadata file itself unwritable, so a guest cannot add itself a row.
This is deliberately *not* the D8 secret class: secret-class files are
denied to the file ABI entirely, which would make the keyring unreadable
by the daemon that must consult it.

**Startup posture** (D2 of ADR 0044 extended, same fail-closed order;
new refusals inserted before `no-root`):

1. `uid_user` + no caps → else `agentd: refuse privileged` (unchanged).
2. `agent-hmac` row present → else `agentd: refuse no-credential`
   (the row stays — D4 makes it the receipt key, no longer a door key).
3. `AGENTS.TXT` present → else `agentd: refuse no-keyring`; present but
   unparseable → `agentd: refuse keyring-malformed`. A valid keyring
   with zero active agents is allowed: the door stays up to name
   `agent_revoked`/`agent_unknown` at each attempt.
4. `/host/AGENT` listable → else `agentd: refuse no-root` (unchanged).
5. `/host/AGENT/AUDIT` listable → else `agentd: refuse no-audit`.
   Audit is not optional in this model; a daemon that cannot receipt
   does not serve. (The alternative — degrade to serial markers — was
   rejected: serial is the ops stream, not the audit trail.)
6. `vi.Listen(4747)` → else `agentd: refuse listen errno=<name>`.

## D2. The handshake — `virelai-agent/2`, agent-named, Ed25519

```
S: {"proto":"virelai-agent/2","auth":"ed25519","challenge":"<64 hex>"}
C: {"agent":"<id>","auth":"<128 lowercase hex>"}
S: {"ok":true,"session":"ready","agent":"<id>","caps":["file",...],"verbs":[...]}
```

- The signature is Ed25519 over
  `"VIRELAI-AGENT/1 ed25519" || 0x00 || challenge[32] || 0x00 || agent_id`
  — the ADR 0024 D6 signature-scheme shape, extended to bind the claimed
  id into the signed message so the id field cannot be swapped under a
  captured signature.
- One auth attempt per connection, 10 s budget, 256-byte pre-auth line
  (the reply is ~183 bytes at the 32-byte id bound — it fits unchanged).
- Refusals, each named and each session-fatal after one error line:
  `agent_unknown` (id not listed), `agent_revoked` (a `revoked=` row
  names the presented key — refused **by name**, the card's bar),
  `auth_failed` (malformed line or signature mismatch),
  `auth_required` (a `verb` key before auth), `auth_timeout`,
  `line_too_long`. The 1 s re-listen damping is unchanged.
- `verbs` and `caps` in the ready line are the session's resolved
  grants: a verb appears iff its cap (D3) is on the row.
- **`virelai-agent/1` HMAC auth is removed, not kept as a second
  scheme.** Two doors means the shared `agent-hmac` row remains a way
  around per-agent identity; there is no deployed base to keep compat
  for — the in-tree harness and spec are rewritten by M109b. Old
  clients fail closed at the greeting.
- The Ed25519 verify rides a leaf package: M109b extracts
  `sshlib/ed25519.go` + the fe51 limbs in `sshlib/x25519.go` to
  `user/go/ed25519` (ADR 0044's no-copy rule; sshlib and flint's
  `sign.go` repoint their imports).
- Per-session identity is resolved once at auth (id, caps, revoked
  check). A mid-session keyring edit takes effect on the next
  session — the D6 "caps resolved per session" contract M109b asked
  for. One client at a time stays (ADR 0044 D1).

## D3. Caps — declared on the row, one vocabulary

`caps=` is a comma-separated subset of the `apps.txt`/WASM Cap words:
`file window audio timer memory process debug net term`. One word
means one thing across the manifest, the keyring and (when it lands)
ADR 0054's grant table. The mapping is fixed:

| Verb | Cap | Note |
|------|-----|------|
| `proc.list`, `proc.get` | `process` | introspection, read-only |
| `fs.read`, `fs.write` | `file` | one word covers both directions in v1 |
| `ui.windows`, `ui.screenshot` | `window` | `ui.screenshot` lands with M109b |
| `gosh.run` | `term` | **and** still AND-ed with `--allow-exec` — the daemon flag is the operator's kill switch, the cap is the per-agent grant |
| *(unmapped)* | `audio timer memory debug net` | reserved for M109b+/M113 verbs; naming a verb-less cap in a row is legal |

`term` rather than `process` gates `gosh.run` on purpose: `process`
stays observe-only, so an agent can hold `file,process,window` — a
monitoring agent — without holding the escape hatch. `gosh.run`
remains the escape hatch it always was (ADR 0044 D2): a cap bounds
the *channel* surface, and a spawned GOSH still runs `uid_user`
unconfined — caps never widen the kernel ceiling (no elevation,
ADR 0024 D5), and they do not confine what a `gosh.run` child does.
(card #3029 amendment: a `uid_agent` parent's children now inherit
`uid_agent`, so the spawned GOSH is confined by the agent's file and
signal rules — see the amendment below.)

**A missing cap is a named refusal**: `cap_required:<cap>` — the
D4 `code:detail` split already carries it — non-fatal, the session
stays open, and the refusal itself is receipted (D4). Marker:
`agentd: refuse id=<n> verb=<v> code=cap_required`.

## D4. The audit contract — receipts in the M108 lane shape

Every dispatch leaves a receipt — allowed **and** refused — plus the
auth outcomes and session open/close. This is what M109c implements
and GOTOP renders.

**Where:** `/host/AGENT/AUDIT/`, staged host-side beside `AGENT/` (the
SDK has no mkdir; D1 posture check 5 refuses without it). One receipt
per file, named `RCPT-<epoch:8hex>-<seq:8hex>` where `epoch` is a
fresh 32-bit `vi.Random` per daemon start and `seq` is per-epoch
monotonic from 1 — the VHI1 epoch+seq pattern, so cross-boot names
never collide. Files inside `AUDIT/` are unreachable through `fs.*`
(the flat `NAME` grammar has no `/`), so an agent cannot read or
rewrite its own log through the channel; `gosh.run` can reach them —
a stated residual, below.

**What one receipt is** (two lines — a JSON object, then its MAC):

```
{"seq":1,"epoch":"<8hex>","agent":"<id>","verb":"fs.write","args":{"path":"HELLO.TXT","size":27,"sha256_8":"<8>"},"ts":<unix s>,"mono":<ns>,"result":"ok"}
<64 lowercase hex HMAC-SHA256(receipt key, line-1 bytes)>
```

- **who** — `agent`: the authenticated id, or `"-"` for pre-auth and
  session-frame events (a failed auth receipts its *claimed* id —
  `"agent":"<claimed>"` — with `result` naming the refusal).
- **what** — `verb` + `args`, bounded metadata: `path` names are
  verbatim (≤ 31 bytes, already a NAME), `cmd` is verbatim (≤ 192
  printable bytes — the audit exists to show what ran; this is the
  stated exception to D6's payload silence), payload bytes are reduced
  to `size` + `sha256_8` and never appear. Session events use
  `verb:"session"` with `args:{"event":"open"|"close"|"auth_fail"}`.
- **when** — `ts` = `vi.Time()` unix seconds, `mono` = `vi.Nanos()`.
- **result** — `"ok"` or the refusal code (`cap_required`,
  `path_rejected`, `agent_revoked`, `auth_failed`, …), with the
  `io_error` detail appended when present.
- A receipt write goes through `WriteFileSafe` (temp + fsync + rename —
  the share's publish rule); the file ceiling is ≈ 600 bytes.

**Authenticity.** The MAC key is the existing `agent-hmac` row — kept,
re-scoped from front-door credential to receipt key, and its `apps`
allowlist widens to `AGENTD.ELF,GOTOP.ELF` when M109c lands the viewer
(one row, no new secret-store slot; the host verifies by reading the
same `SECRETS.TXT` line as a file — the M108 double-reader pattern).
A forged or edited receipt fails the MAC; GOTOP marks receipts
`verified`/`unverified`, the host can verify offline.

**Bounds and rotation.** `AUDIT/` holds ≤ 64 receipt files; at the cap
the daemon deletes the lexically smallest `RCPT-` name (epoch+seq
ordering is chronological) and emits `agentd: audit drop <name>`.
Drop-oldest loses history — stated, not hidden: the canonical archive
is the host, which owns the share folder and may drain `AUDIT/` at any
time (a later `vgate_run` on the same share sees the same files — the
go-flint second-machine pattern already relies on this).

**Honest residuals.** (a) An agent holding the `term` cap can reach
`AUDIT/` through a shell line — same uid, same share — so receipts are
tamper-*evident* (MAC'd), not tamper-*proof*, for agents trusted with
`gosh.run`; the receipt of the `gosh.run` call itself is written before
the child starts, so the attempt is on record even if the trail after
it is edited. A kernel-anchored audit lane is M113 trust-depth
territory. (b) The image-binding residual stands: any exec'd
`AGENTD.ELF` can read the receipt key (the accepted M97g/M108
posture). (c) One daemon, one session: receipts from overlapping
agents cannot exist because overlapping sessions cannot exist.

## D5. Concurrency — the M99g answer, observed

**Question (from the card):** M109d runs `flint push` from inside a
`gosh.run` while AGENTD holds its socket. Does that work?

**Answer: yes — observed, not inferred.** `just gate live-ssh-server`
was run on this host 2026-10-16 on branch `agent/devin/m109a-adr` at
`d0a14b6d` (log: `artifacts/live-ssh-server-m109a.log`):

```
=== result ===
vgate live-ssh-server: PASS (3/3 runs)
--- [1/1] PASS live-ssh-server (169s)
FLEET RESULT: 1/1 PASS
```

Run 03 is the leg that answers the question (`m99z-net`): AGENTD.ELF's
listener on 4747, GOSSHD.ELF serving two concurrent SSH sessions, and
WEB.ELF's outbound fetch to `10.0.0.2:80` through the runner's relay
responder — all live together in the one socket table, and the pcap
walk proved three distinct 5-tuples with the web window strictly
inside the SSH window:

```
m99z-net ok: agentd listener + 2 concurrent SSH + web fetch, 3 distinct 5-tuples, web window inside ssh window
```

`flint push` inside `gosh.run` is the same shape: a spawned process
takes an op-10 `vi.Dial` handle while the daemon's listener keeps its
slot. **M109d is not blocked on the socket question.**

What replaced the singleton is a *bounded table*, so the residual is
capacity, not exclusivity: `conn_limit = 4` connections and
`owner_limit = 4` sockets per owner system-wide
(`socket_core.zig:31-41`) — a new open past the table is `ENOSPC` →
`ErrConnBusy`, the named busy refusal moved to a different wall — and
`scheduler.max_tasks` 16 with ~3 task slots per `GOMAXPROCS=1` Go
runtime (agentd + seat + GOSH + FLINT ≈ 12 — inside, without much
margin; the `live-agent-loop` spec should carry the same GOMAXPROCS
pin `live-ssh-server` does).

**The ADR 0044 amendment** lands with this PR: the "Not provided"
bullet "TCP for anything else in the guest while AGENTD.ELF holds the
socket … fail as busy" is struck and replaced with the bounded-table
statement above — that line was written when TCP was a process-wide
singleton, and M99g retired the premise.

## D6. What does not change

- ~~The authority ceiling: the daemon and everything it spawns run
  `uid_user`, caps 0. Agent identity is channel-level; the kernel
  knows processes, not agents. Per-agent *kernel* principals (a uid
  per agent) need a principal-assignment path EL0 cannot reach — that
  is trust-depth work, M113's territory.~~ **Superseded by the card #3029
  amendment below (2026-10-22, card #3029):** a single agent
  principal `uid_agent`, assigned by the kernel at exec on the
  `AGENTD.ELF` image name — the EL0-unreachable assignment path this
  bullet said was missing. Caps stay 0; per-agent uids stay deferred.
- One client at a time on 4747; the plaintext-session posture (E6 of
  ADR 0044 still owns transport hardening); the never-logged contract
  for secrets, MACs and payload bytes (receipt args are metadata —
  `cmd` text is the stated exception).
- `agent-sign` (the FLINT author seed, `user/go/flint/sign.go:9`)
  stays one shared seed in v1: all agent-sourced Changes carry the
  same author key, and the receipt is what attributes them to the
  agent id. Per-agent author keys would need per-agent seed rows in
  the 8-entry store — a named residual, not this arc.
- The boot default, the kernel, the syscall table, the runner —
  untouched except a possible new slot for `ui.screenshot`, which is
  M109b's own ADR 0007 amendment if needed.

## D7. Card split — file-level Touches for M109b–e

Lanes per the index's corrected order: **b → {c ∥ e} → d → f** (b and
c both hold `user/go/agentd/*`; c and e are disjoint).

| Card | Issue | Touches |
|------|-------|---------|
| M109b | #2398 | `user/go/agentd/*`, `user/go/ed25519/*` (new leaf — the extracted `sshlib/ed25519.go` + `x25519.go` fe51 limbs), `user/go/sshlib/*` (import repoint), `user/go/flint/sign.go` (import repoint), `tools/agentctl/*` (Ed25519 client signing), `tools/gate/specs/go-agentd.spec`, `docs/decisions/0007-syscall-abi.md` (only if `ui.screenshot` needs a slot) |
| M109c | #2399 | `user/go/agentd/*` (receipt writer), `user/go/top/*` (viewer), `tools/gate/specs/go-agentd.spec`, `tools/gate/specs/go-top.spec` |
| M109d | #2400 | `tools/gate/specs/live-agent-loop.spec`, `tools/gate/fixtures/agent-app/*` |
| M109e | #2401 | `user/go/gotabwm/*`, `user/go/tabapp/*`, `tools/gate/specs/go-wm-seat.spec` |
| M109f | #2402 | `tools/gate/specs/live-agent-loop.spec`, `docs/status.md` |

Where this table widens a card's printed `--touches` (M109b gains the
Ed25519 extraction and `tools/agentctl/*`), the table wins and the card
is claimed with these paths.

This card's own Touches: `docs/decisions/0052-agent-identity.md`,
`docs/decisions/0044-agent-control-channel.md`. Nothing else.

## Consequences

- Agents stop borrowing the human's credential: one row provisions,
  one row revokes, and revocation keeps attribution because the row
  stays.
- The guest holds no usable agent credential at all — a keyring file
  of public keys — so the D8 store's 8-entry bound is not spent on
  principals, and the only agent-side secret is the daemon's own
  receipt key.
- `virelai-agent/1` HMAC auth ends; `agentctl` and the `go-agentd`
  spec are rewritten by M109b. There is no transition window — the
  proto bump fails old clients closed at the greeting.
- Audit is mandatory posture, not a flag: no `AUDIT/` directory, no
  daemon.
- The concurrency answer unblocks M109d with a cited run; the real
  bound is the socket table and task pool, both stated.

## Rejected alternatives

- **Per-agent symmetric keys in `SECRETS.TXT`** (`agent-hmac-<id>`
  rows — the D8-literal reading). The store is 8 entries, fixed in the
  kernel (`secret.zig:76`) with no M109 card touching it; a full share
  already spends ~7 names; the row grammar has no status field, so
  revocation would be deletion — losing the id↔key map audit needs.
  And every symmetric row is a usable credential sitting in the guest.
  The public-key keyring carries status, scales within its own file
  bound, and holds nothing usable.
- **Shared `agent-hmac` door + a per-agent signature inside the
  session.** The door key stays shared — revoking one agent cannot
  close its door — and two auth layers buy nothing over one.
- **A per-agent kernel uid.** `sys_exec` has no principal argument and
  the only naming path is the EL1h monitor's `exec -u<uid>` (ADR 0024
  D5); wiring agent ids to uids is a kernel/trust-model card, not this
  one. Channel-level identity needs no syscall.
- **Receipts as VHI1 records in `HOSTINT/`.** The seat consumes and
  deletes lane records — audit wants persistence and an agentd
  producer, not a seat lane. The *shape* (one record per file,
  seq-named, bounded, signed) is what this ADR reuses.
- **Unsigned receipts.** Any `uid_user` app could plant or edit them;
  the MAC costs one already-provisioned row and makes forgery a named
  failure.

## Open questions / deferred

- Per-agent `flint` author keys (per-agent Ed25519 seeds) — the
  8-entry secret store is the wall; deferred to the trust-depth arc.
- Whether `AGENTS.TXT` wants non-cap metadata fields later (`opens=`,
  display names). The grammar refuses unknown keys today; extending it
  is an amendment, not a parse-mode change.
- Seat-indicator event vocabulary (which agent events warrant chrome)
  is M109e's design space; this ADR only guarantees the receipt stream
  exists for it to read.
- Multi-agent concurrency policy beyond one-session-at-a-time stays
  the index's explicit non-goal.

## Risks and stop conditions

- **ELF ceiling.** Agentd sits at 1,769,632 of 2,097,152 bytes. The
  Ed25519 leaf (~800 lines incl. fe51), the keyring parser and the
  receipt writer are the growth. If `build-agentd.sh` refuses on size,
  stop: the fix is a slimmer split (the receipt writer reuses the
  wire.go encoder), never copying crypto or shrinking a bound silently.
- **Host-side signing.** Python stdlib has no Ed25519 — M109b chooses
  the mechanism (a small fresh RFC 8032 implementation pinned to the
  in-tree TEST vectors, or a host-Go helper). If neither lands cleanly
  the card stops and says so; the wire shape does not change.
- **A row format fight at review.** If owner review prefers the
  symmetric-rows model despite the bound, the rejected-alternatives
  section already prices the swap: `AGENTS.TXT` keeps caps/status, the
  credential half moves to `SECRETS.TXT`, and the agent count becomes
  "as many as the 8-entry store can spare" — stated, not papered over.

## Amendment (2026-10-22, card #3029 / card #3029): the agent principal

D6's first bullet is superseded. Its premise — that a kernel principal
needed "a principal-assignment path EL0 cannot reach" and none existed —
was retired by the grant table (ADR 0054 D7): exec already records the
image name, and grants already key on it. the agent-principal arc (index #3025, owner
decisions D12/D13/D15/D16) spends that binding on a principal: **the
agent is `uid_agent = 2000`.** The channel identity this ADR built —
*which* agent signed in — is unchanged and stays the receipt label; the
kernel principal answers *whether* a process is the agent's.

- **Who gets it.** Any process whose exec records the image name
  `AGENTD.ELF` — the same recorded name grant rows and the M97g label
  binding already key on (`kernel/src/grant.zig:6-8`). The binding is
  name-only and the M97g caveat applies honestly: any EL0 process can
  stage or exec an image under that name and thereby *become* the
  agent. That is acceptable here because `uid_agent` only ever
  narrows — the squatter loses `uid_user`'s write reach, gains write
  only inside the agent-owned roots, signals nothing outside
  `uid_agent`, and receipts thereafter say `uid=2000`: becoming the
  agent is exactly the act the principal exists to see.
- **How it is assigned.** By the kernel at exec — never by an EL0
  request (`sys_exec` still takes no principal argument, ADR 0024
  D5/D10) and not by the monitor's `exec -u<uid>`, which stays the
  admin surface it was. Children of a `uid_agent` process inherit
  `uid_agent`, so a `gosh.run` child can no longer escape into
  `uid_user`; caps stay 0 on both. The daemon's startup posture (D1
  check 1) flips to match: `uid_agent` + no caps, else
  `agentd: refuse privileged`.
- **What it can touch** (index D16). On user files the agent is never
  the owner, so `trust.check` reads the *other* triplet
  (`kernel/src/trust.zig:239-269`): on the default `0644` it reads and
  cannot write; `0600` files and the secret class are closed outright.
  The two roots the daemon must write — `/host/AGENT` (the D1 sandbox)
  and `/host/AGENT/AUDIT` (the D4 receipt directory) — get kernel-minted
  `uid_agent`-owned rows, the `ensure_meta_file` default-row pattern, so
  the agent writes there as owner while `uid_user` keeps read through
  the other triplet. `GOVAULT`'s `VAULT.BIN` becomes `0600`: the vault
  stays sealed either way — `0600` removes the ciphertext itself from
  the agent's read set.
- **Who can stop it** (index D12). The D10 kill posture gains one
  asymmetry: `uid_user` may signal `uid_agent` — the human can always
  stop the agent — while a `uid_agent` caller may signal only
  `uid_agent` targets. `CAP_PROC_ADMIN` is unchanged, and the principal
  check still runs before the target-state checks.
- **What the audit says.** Kernel receipts gain `uid=` (the RCPT line,
  `kernel/src/measure.zig`): `name=` records what ran, `uid=` records
  as whom. The audit split inverts cleanly — `AUDIT/` is agent-owned,
  so the agent's own `gosh.run` child can still rewrite the *userland*
  trail (D4 residual (a) re-based on `uid_agent`, tamper-evident by MAC
  as before), while the kernel receipts — serial plus `RCPT.TXT`,
  published below the file ABI — are the trail no `uid_agent` process
  can edit.
- **Deferred** (per index #3025): per-agent uids — one agent principal
  this wave, `AGENTS.TXT` ids stay channel-level labels — VLFS
  ownership (index D13; the inode reservation is card #3028's ADR), and
  multi-user.
