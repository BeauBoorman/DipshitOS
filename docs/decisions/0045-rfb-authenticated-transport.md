# ADR 0045: Authenticated remote-desktop transport — RFB over an SSH channel terminated in-seat

- Date: 2026-10-12
- Status: **Proposed** — awaiting owner review. No code lands here; this
  ADR is the card (#2204) and, if approved, the split below is the arc.
- Card: **#2204** (Go apps second pass, program index #2205). Depends on
  #2145 (agentd) reaching owner close-out — satisfied: `AGENTD.ELF`
  landed, `go-agentd` 8/8 on the reference host (ADR 0044).
- Related: ADR 0024 (trust baseline), ADR 0025 (SSH profile), ADR 0037
  (remote display — serving shape and auth posture), ADR 0044 (agent
  control channel), ADR 0007 M97g amendments (clipboard consent, F4).

> `user/go/rfb` is a complete RFB 3.8 server codec that offers exactly
> security-type None, restricted by ADR 0037 D6 to the hermetic runner:
> "remote use is unsupported until an authenticated transport exists."
> This ADR picks that transport. Decision: **an SSH-2 channel inside the
> existing sshlib server profile, terminated by the seat itself** — the
> standard `ssh -L` shape, so the codec's None posture is never asked to
> carry a routable byte. Full remote desktop is the goal; read-only
> viewing is the default posture within it; and it is a small milestone
> arc, not one card.

## Grounding (observed in tree `d83e15a7`, 2026-10-12)

- **The codec is transport-agnostic by requirement.** `rfb.NewSession`
  takes an `io.Reader`/`io.Writer` pair; it does not listen, dial,
  authenticate, compose, or inject (`user/go/rfb/doc.go:1-5`). ADR 0037
  D6 made this shape a hard requirement on M84b precisely so a later
  transport card could plug an authenticated channel in without touching
  the codec. Its trust-boundary doc states the posture in one breath:
  None only, hermetic runner and a same-user localhost bridge only,
  "never expose this codec as direct RFB on a routable network"
  (`doc.go:7-15`).
- **The in-seat server exists and is hardened.** `GOTABWM.ELF
  --rfb-hermetic` binds `vi.Listen(5900)`, serves one viewer, diffs the
  seat's own scanout mapping, and synthesizes remote input through
  `consumeSeatEvent` — the identical function hardware input takes
  (`user/go/gotabwm/rfbserver.go:69-90`, `:256-275`; ADR 0037 D1/S1/S2).
  Session teardown names its drop reason and releases a dead viewer's
  held press (`:95-129`, `:278-289`); `live-rfb` is 6/6 on the negatives
  and the viewer-death sweep (status.md M84 row).
- **TCP is now a bounded table, still no loopback.** M99f (#2184,
  landed 2026-10-12) promoted `socket_core.Core` to the system socket
  table: **4 listeners system-wide (≤1 per owner), 4 connections, 2
  children per listener, 4 sockets per owner**, `ENOSPC` on over-cap,
  with legacy slots 30–33/76 as a per-process shim over it (one
  listener + one outbound per process — the `vi.Listen`/`vi.Dial`
  surface is unchanged). Its class-B proof ran **three coexisting
  listeners in the sshd+agentd+rfb shape** (ADR 0007 M99f amendment).
  ADR 0037 §S3's "one system-wide connection" — and its D4 co-tenancy
  consequence — are superseded. Still true: **no TCP loopback** — an
  own-IP connect is refused `.no_peer` (`kernel/src/tcp.zig:29-31`).
  `payload_max` is 1460 (M84e).
- **Reachability is unchanged from ADR 0037 §S4 (recorded negatives,
  still true).** There is no NAT port-forward, no runner host-listen
  bridge, and no guest SSH `-R` (`user/go/ssh` has no remote-forward).
  The only host→guest TCP path is the runner's hermetic
  `--net-tcp-connect` stream adapter — same user, same machine.
- **agentd's channel is request/response JSONL.** TCP 4747, HMAC-SHA256
  challenge on a dedicated `agent-hmac` key, fail-closed posture,
  **256 B lines before auth and 8192 B after**, byte payloads as padded
  base64, at most 4096 decoded bytes per `fs.*` call, and — stated, not
  hidden — **no post-auth confidentiality, integrity, or replay
  protection: the stream is plaintext** (ADR 0044 D1–D4). One client,
  in-order, one response per request.
- **sshlib is a real SSH-2 stack, client and server.** The server speaks
  the ADR 0025 D2 profile: `curve25519-sha256` KEX, `ssh-ed25519` host
  key, `chacha20-poly1305@openssh.com` (AEAD — session confidentiality,
  integrity, forward secrecy), `publickey` auth against
  `SSH/AUTHORIZED_KEYS` (`user/go/sshlib/server.go`; GOSSHD.ELF is the
  shipping server, `user/go/sshd/main.go`). **It accepts exactly the
  `session` channel type** — anything else is `unsupported channel
  type` (`server.go:600-603`) — and one `exec` request per channel
  (`:617-669`). There is **no `direct-tcpip`, no `tcpip-forward`, no
  client `-R`**, and the server's channel data path is send-output-then-
  close (`sendChannelData` → EOF → close, `:654-660`): no long-lived
  bidirectional channel exists yet.
- **The auth-key provisioning pattern is proven and app-bound.**
  `SECRETS.TXT` entries bind a secret to an image:
  `ssh-host-ed25519<TAB>1000<TAB><seed><TAB>GOSSHD.ELF`, served only to
  a `uid_system`-owned image through `sys_secret_get` (ADR 0024 D8,
  M97g #2083; `live-ssh-server.spec` stages exactly this). Public pins
  live in the plain share file `SSH/AUTHORIZED_KEYS`
  (`name<TAB>ssh-ed25519<TAB>hex-pubkey`).
- **The consent precedent is M97g-F4 (#2082).** Programmatic clipboard
  access was a silent harvest until slots 38/39 were gated to
  `CAP_CLIPBOARD` **or the kernel-registered WM seat** — "the seat owns
  the raw input fan-out and renders the tray's clipboard indicator, so
  its probe is user-mediated by construction" (ADR 0007 M97g amendment).
  The transferable rule: a privileged user-data or input seam is
  acceptable when the seat is the choke point **and** the seat makes the
  activity visible.
- **The seat is the only place a remote-desktop session can live.** The
  scanout bind is seat-exclusive (`wm_server.scanout_bind` requires
  `pid == wm_pid`), there is no EL0→EL0 input-injection syscall, and
  the only injection point is in-process synthesis into
  `consumeSeatEvent` (ADR 0037 S1/S2). A separate daemon process can
  neither read the frame nor inject input without new seams ADR 0037
  already surveyed and rejected (§S6).
- **ELF ceiling.** Guest images are capped at 2,097,152 bytes
  (`tools/go/build-*.sh` `MAX_BYTES`; `exec_program_max`). `AGENTD.ELF`
  observed 1,769,632 B (ADR 0044 amendment). sshlib is ~3.6 kLOC shared
  with GOSSH/GOSSHD.

## D1. Carrier: an SSH-2 channel through sshlib, terminated by the seat

The transport is an SSH-2 session per the ADR 0025 D2 profile, ending
**inside the seat process**. The seat runs the sshlib server profile on
`vi.Listen`; the viewer's client opens a `direct-tcpip` channel whose
bytes are pumped to `rfb.NewSession` in-process — the same codec, the
same `consumeSeatEvent` input path, the same frame-diff loop the
hermetic server uses today. RFB's `security-type None` never leaves the
channel: authentication, confidentiality and integrity are properties
of the carrier, exactly as `ssh -L` protects any unauthenticated
protocol.

`direct-tcpip` (RFC 4254 §7.2), not a custom channel type, is the
chosen shape so that **stock tooling works unmodified**: a client that
can SSH and forward a port — `ssh -L`, OpenSSH, PuTTY, any
VNC-over-SSH recipe — can reach the desktop with no new wire format.
The seat accepts `direct-tcpip` for exactly one advertised target (the
in-process codec; the channel request names it, e.g. `virelai-rfb`)
and refuses every other target, every `session`/`exec` variant it does
not implement, and `tcpip-forward` — the seat is an RFB endpoint, not
a general TCP proxy (and could not proxy anyway: no guest loopback).

The multiplexing consequence is worth stating even post-M99f: the
table is bounded (4 connections), and SSH channels recover
application-layer multiplexing on one connection — one SSH session
could later carry RFB and a shell channel side by side (a recorded
possible extension, not this arc).

### The honest trade of the three candidates

|| agentd JSONL | sshlib SSH channel | new dedicated transport |
|---|---|---|---|
| Auth | HMAC-SHA256 shared secret (`agent-hmac`), per-connection challenge | Ed25519 publickey vs `AUTHORIZED_KEYS` + pinned host key | would need a third credential domain and a third crypto profile |
| Confidentiality | **none post-auth — plaintext** (ADR 0044 D2 "not provided") | AEAD every packet; forward secrecy | only if a TLS server existed — M53 shipped a client only |
| Shape | request/response lines, ≤8192 B, base64 bytes, ≤4096 B/call | bidirectional byte stream, channel flow control | would be built for streaming |
| Fit for a framebuffer | bad: one raw frame is 3,686,400 B → ~4.9 MB base64 → ~600 lines **per frame**, ordered behind every other request; input head-of-line blocked behind frame sends | natural: the codec is already `io.Reader`/`io.Writer` | natural, at the cost of building everything |
| Tooling | `agentctl.py` only | stock `ssh -L` + any VNC client recipe | nothing |
| Exists today | yes | server profile yes; `direct-tcpip` + a bidirectional channel **no** | no |

**agentd JSONL is rejected as the RFB carrier**, not because it is
immature — it is landed and green — but because its shape is wrong for
a byte stream regardless of maturity: base64 costs ~33% on the single
most expensive stream the system produces, the line grammar forces
~600-message fragmentation per full frame, its strict one-request-one-
response ordering puts pointer input behind multi-second frame sends,
and its post-auth plaintext would carry the literal screen contents —
the most sensitive bytes in the system — in cleartext. Its authority
model is also verbs-and-sandbox, not "the local user's input path."
It stays what ADR 0044 made it: the agent control channel. A bounded
one-shot screenshot verb is a reasonable read-only-observation
intermediate — and it belongs to 0044's E5 epic, not to this transport.

**A new dedicated authenticated transport is rejected**: it duplicates
auth machinery the tree already proved twice (HMAC in agentd, full
SSH-2 in sshlib), invents a third credential domain, speaks to no stock
tooling, and the only crypto that would make it competitive (a Go TLS
server) does not exist — M53 was client-only (ADR 0037 D6, Open
issue 3).

**Fronting RFB on GOSSHD is rejected** even though it is the intuitive
"SSH server serves RFB" topology: GOSSHD is a separate process from the
seat, and there is no guest TCP loopback, no cross-process input
injection, and no non-seat scanout access. Connecting GOSSHD to the
desktop would need a new frame-plus-input seam between processes —
exactly the snapshot-fed-daemon fallback ADR 0037 §S6 measured and
rejected — plus a new cross-process authority story D3 below would not
have. In-seat termination is the only topology where every required
seam already exists.

## D2. Auth story: the GOSSHD profile, rebound to the seat

Reused verbatim from the proven server, with one provisioning
difference:

- **Host key:** an Ed25519 seed in `SECRETS.TXT`, **app-bound to
  `GOTABWM.ELF`** under a distinct key name (implementation card picks
  it; `ssh-host-ed25519` stays GOSSHD's). GOSSHD's own key is not
  shared: separate image, separate credential, separate blast radius.
- **Client auth:** `publickey` with `ssh-ed25519` against the existing
  `SSH/AUTHORIZED_KEYS` share file. No second identity file, no
  password auth, no `none` method, no unauthenticated channel open.
- **Startup posture (fail closed, before `vi.Listen`),** the agentd D2
  order: uid must be `uid_user` with caps 0; the host-key secret must
  be present; `SSH/AUTHORIZED_KEYS` must exist and hold ≥1 key;
  explicit start flag required. Any failure prints one marker and the
  seat's remote mode simply does not arm — **there is no fallback to
  the None listener**, and `--rfb-hermetic` remains a separate,
  unchanged, hermetic-only invocation.
- **Provided by the carrier:** confidentiality, integrity, forward
  secrecy, server authentication to the pinned host key, client
  authentication to the authorized list — the ADR 0025 D7 list.
- **Not provided:** the RFB handshake inside the channel still offers
  None — correct, because the channel is the authentication boundary.
  A session-level `authed` marker in the seat's logs records which
  carrier a session rode so a gate can assert pixels only ever crossed
  an authenticated channel (cheap honesty, T2's detail).
- **Never-logged contract** as in ADR 0044 D6: the seed, KEX material,
  and client keys never reach serial, `APPLOG`, or crash receipts.

## D3. Authority: remote input is armed seat authority; viewing is the default

ADR 0037 D3's statement stands and is now load-bearing across a real
boundary: **remote input === local input** — pointer and key messages
synthesize into `consumeSeatEvent` inside the registered seat, so a
remote viewer can do exactly what the local user can do, against
exactly the seat that terminated the channel. There is precisely one
registered seat (`wm_pid`); remote input cannot be aimed at another
seat, a specific app, or a second display — it routes by the seat's
focus, as hardware input does.

That answer is honest but insufficient alone, so this ADR adds the
consent layer the card asks for, built on the M97g-F4 precedent:

- **Who may inject:** only a party that authenticated as an
  `AUTHORIZED_KEYS` holder — the operator tier — **and** only while
  the seat's remote-input arm is on. The channel authenticates the
  *viewer*; the arm authorizes *input*. These are separate decisions.
- **View-only is the default posture.** A serving mode armed without
  input drops KeyEvent/PointerEvent messages with a named marker and
  keeps the session — a remote viewer may always watch; it may not
  silently drive.
- **The arm is an explicit operator act**, not a negotiated client
  request: a distinct start flag (e.g. serving flag plus `-input`;
  exact argv is T2's) — the same authority class as "whoever configures
  and starts the seat." There is **no RFB-side or channel-side request
  that can grant it**: a viewer asking for input authority is a refusal,
  not a negotiation.
- **Visibility, per M97g-F4:** while any remote session is live the
  seat paints a remote-session indicator in chrome it owns (rail/tray
  state — the seat already renders indicators for exactly this class of
  state). Remote control is never invisible to the person physically at
  the machine, whose hardware input preempts and who can kill the mode
  outright. This is the clipboard-consent analog: seat as choke point
  **plus** user-visible signal.
- **Session death is honest:** the M84d contract carries over — a
  dropped authenticated session releases any held press at its last
  point before local input resumes.

## D4. Exposure: hermetic by default; routable only ever over SSH

- **The default does not move.** Today there is no routable path to
  guest TCP at all (Grounding: recorded negatives). The SSH endpoint
  binds only on explicit start under the D2 posture checks — never the
  boot path, never autostart, no `SERVICES.JSON` row. A boot that never
  starts it is byte-identical to today.
- **What may bind a routable listener, when one day one can:** an
  SSH-terminating endpoint only. If a future card creates reachability
  (a NAT/host port-forward story — ADR 0037 Open issue 1 — or guest
  `-R` dial-out — Open issue 2, needing client-side `tcpip-forward`),
  the remote surface is this SSH channel. **Direct RFB/None on any
  routable socket remains refused in every posture**: the codec's
  None-only restriction is a load-bearing decision (ADR 0037 D6), not a
  gap this arc relaxes. `--rfb-hermetic` stays the test-only listener
  it is.
- **What this ADR does not claim:** real-machine remote reachability.
  It does not exist today; the authenticated transport is designed so
  that when a reachability card lands, remote access arrives already
  authenticated and encrypted. On today's topology the practical
  deployment is the runner's hermetic stream (gates, same-user
  operation) and, on real iron, a host-side `ssh -L`-style bridge whose
  guest leg is this channel.
- **Co-tenancy honesty:** post-M99f the seat's listener no longer
  starves other guest TCP services — agentd, GOSSHD and the seat's
  endpoint can hold listeners simultaneously (the socket table's own
  class-B proof ran exactly that shape). The bounds are real, though:
  4 listeners and 4 connections system-wide, ≤1 listener and 4 sockets
  per owner; an over-cap bind is `ENOSPC`, named, never queued.
  Channel multiplexing remains the mitigation inside those bounds (D1).

## D5. Scope lines: an arc, not a card

The work below is bigger than one card and each shard is independently
landable with disjoint touches. If this ADR is approved, the split is:

| Card | Deliverable | Touches (indicative) |
|---|---|---|
| **T1 — sshlib server channels** | `user/go/sshlib` server grows `direct-tcpip` channel opens with a bounded target allowlist callback, and a real bidirectional channel-data path (window/adjust flow control, EOF/close both directions) — the current `session`+exec-then-close path is not one. Class-A unit tests: open/confirm, target refusal, window exhaustion, half-close. No seat or sshd change. | `user/go/sshlib/**`, `user/go/sshd` tests only |
| **T2 — seat SSH endpoint + RFB session** | `GOTABWM.ELF` remote mode: explicit start flag, D2 posture checks, sshlib server profile on `vi.Listen`, `direct-tcpip` target `virelai-rfb` → in-process `rfb.Session`; view-only default, input arm flag, seat indicator while live, `authed` markers. Reuses `rfbserver.go`'s diff/input/drop machinery over a channel adapter. | `user/go/gotabwm/**`, `docs/decisions/0045` (status flip), `docs/testing.md` |
| **T3 — class-B gate `live-rfb-ssh`** | Hermetic `--net` spec proving the authenticated path end to end: pinned host key + authorized client key → direct-tcpip → RFB handshake → pixels + armed input; negatives — bad client key refused before any channel, non-`virelai-rfb` target refused, view-only mode drops input, key material never logged; the None listener is **not** bound in these runs. Needs a host-side SSH client that opens `direct-tcpip` (extend the runner's `:ssh` stream client or a scripted peer — T3's call). | `tools/gate/specs/live-rfb-ssh.spec`, runner stream client if needed |
| **T4 — docs/closeout** | status row, ADR → Accepted with observed figures, acceptance comment on #2204's program index. | `docs/status.md`, this ADR |

**Explicit non-goals for the whole arc** (stated so no card "discovers"
them mid-flight):

- No codec change. `user/go/rfb` offers None, period; no guest-side
  VNC password, no new security type. (VeNCrypt/TLS remains the ADR
  0037 Open-issue-3 card — the alternative direct-RFB future, needing
  a Go TLS server that does not exist.)
- No kernel change, no new syscall, no runner flag required by this
  design. Reachability work, whenever it lands, is its own card and may
  then touch the runner.
- No LAN/remote exposure in this arc; no NAT port-forward claim; no
  guest `-R` (follow-up). No multi-viewer. No RFB clipboard channel,
  audio, file transfer, or desktop-resize beyond the codec's bounds.
- No boot-path or autostart wiring. No weakening of `--rfb-hermetic`,
  the codec posture, or the `live-rfb` negatives.
- No `session`/exec or `tcpip-forward` on the seat's endpoint in v1 —
  multiplexed shell-over-the-same-connection is a recorded possible
  extension, not a commitment.

## Consequences

- The codec's transport-agnostic shape pays off exactly as ADR 0037 D6
  planned: the authenticated transport plugs in without touching
  `user/go/rfb`.
- The seat grows a second network endpoint beside the hermetic RFB
  listener. The seat is already the trust hub (WM_RPC, hosted apps,
  scanout, input fan-out); this concentrates remote-desktop authority
  there deliberately, under F4's visibility rule, rather than inventing
  a cross-process authority story.
- sshlib's server profile stops being exec-shaped: a maintained
  bidirectional channel is the real new code (T1).
- Remote use stops being "unsupported" **over the authenticated
  channel only**. The sentence in `rfb/doc.go` remains true of bare
  sockets; a docs touch in T2 narrows it honestly rather than deleting
  it.
- When a reachability card lands later, no re-design is needed: the
  remote surface is already authenticated and encrypted.

## Risks and stop conditions

- **ELF ceiling.** sshlib's server profile inside `GOTABWM.ELF` may push
  the image over 2,097,152 B. Measure first (T2 gate of entry); if it
  does not fit, profile the server to the RFB subset (no exec/GOSH
  plumbing) — **copying sshlib is forbidden**; record any extraction as
  an amendment here and in the claim's Touches. If it still does not
  fit, stop and report; do not grow `exec_program_max` for this.
- **Channel correctness is the risky code.** A half-implemented
  bidirectional channel (the current server path is send-then-close)
  can wedge a viewer or leak flow-control state; T1's class-A matrix
  exists for that reason.
- **Attack surface in the trust hub.** The seat terminating SSH means
  KEX/auth/codec hostile-input handling all live in the compositor's
  process. Mitigations: fail-closed posture, one viewer session in v1
  (the listener's second child slot is unused — multi-viewer is a
  named non-goal), the
  codec's existing drop-reason/panic-containment discipline
  (`rfbDropPanic`), and view-only default.
- **A deferral was considered and rejected.** "Wait for agentd to
  stabilize" does not apply: agentd is landed, and its line grammar is
  wrong for this job regardless of maturity (D1). "Needs virtio input
  injection first" does not apply: the recorded injection path is
  in-seat synthesis (ADR 0037 S2/D1) and already ships. The design is
  ready to decide; only reachability is legitimately deferred — and
  it is deferred to a named card, not silently assumed.

## Rejected alternatives

- **agentd JSONL as the carrier** — D1's table: wrong shape
  (request/response, base64, fragmentation), no confidentiality, wrong
  authority model.
- **A new dedicated authenticated transport** — third credential
  domain, no tooling, and no TLS server exists to give it teeth.
- **GOSSHD-fronted RFB** — no loopback, no cross-process input, no
  non-seat scanout; revives the seam ADR 0037 §S6 measured and
  rejected.
- **A custom `rfb@…` channel type instead of `direct-tcpip`** —
  simpler to implement, but no stock client speaks it; the `ssh -L`
  story (standard tooling unmodified) is a headline property.
- **Adding a password or challenge security type to the codec** —
  ADR 0037 D6 already refused guest-side weak auth; the channel
  authenticates, the codec stays pure.
- **Letting the client request input authority** — a negotiation a
  hostile or confused viewer could game; the arm is operator-side
  only (D3).

## Open issues (named follow-ups, not this arc)

1. Guest SSH `-R` dial-out (the pure-SSH real-device path; needs
   client-side `tcpip-forward`) — ADR 0037 Open issue 2.
2. A production host→guest reachability path — ADR 0037 Open issue 1.
3. VeNCrypt/TLS direct RFB — needs a Go TLS server; ADR 0037 Open
   issue 3.
4. `session`/exec multiplexing on the seat's endpoint (shell + desktop
   over one connection).
5. A bounded one-shot screenshot verb on agentd (ADR 0044 E5) as the
   cheap read-only-observation intermediate.
6. A local grant/revoke chord for the input arm, if the owner wants
   live consent rather than start-flag consent.

## Observed vs inferred (AGENTS.md)

- **Observed** (read from the tree at `d83e15a7` or cited from landed
  ADRs): codec shape and None posture; in-seat server and its drop
  discipline; sshlib server accepting `session` only, exec-then-close
  channel path, no `direct-tcpip`/`-R` anywhere in tree; agentd line
  limits, base64 payload rule, and its stated no-confidentiality;
  `SECRETS.TXT` app-binding and `SSH/AUTHORIZED_KEYS` format;
  the M99f bounded socket table and coexisting listeners; no TCP
  loopback; absent host→guest reachability;
  the F4 consent rule; the 2 MiB ELF ceiling and AGENTD's observed
  size.
- **Inferred (design judgment, not measurement):** `direct-tcpip` is
  the right channel shape for stock tooling; the in-seat SSH endpoint
  fits the ELF ceiling with profiling (flagged as T2's entry
  measurement, not assumed); seat-termination's attack-surface cost is
  worth the zero-new-seam benefit. The base64/fragmentation arithmetic
  in D1's table is computed from observed constants, not measured on
  the wire.
- **Not decided here:** the exact start-flag argv, the host-key secret
  name, the channel target string, the indicator's visual form — all
  T2's, recorded there when implemented.
