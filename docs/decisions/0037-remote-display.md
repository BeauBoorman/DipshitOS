# ADR 0037: Remote display — the seams, the serving shape, and the auth posture

- Status: **ACCEPTED** · Date: 2026-09-27 · Milestone: **M84** (remote
  framebuffer) · Index **#1807** · Card **#1809** (M84a, this ADR)
- Related: ADR 0007 (syscall ABI), ADR 0009 (event wire), ADR 0015
  (userland WM seat), ADR 0016 (shared-anon), ADR 0020 (terminal seam /
  net front-end), ADR 0022 (remote console), ADR 0024 (trust baseline),
  ADR 0025 (SSH client-first), ADR 0031 (guest self-test), ADR 0033
  (GOTABWM is the tabbed desktop — no second compositor)
- No code lands here. No kernel change is required by anything decided
  below; had a seam been missing, this card's exit was to stop and
  report, not to detour (none was).

> Measures, before any RFB byte is written, what an RFB server can see
> and what remote input may touch: the frame source, the input injection
> point, the TCP listen seam, and host→guest reachability. Decides the
> serving shape (in-seat vs snapshot-fed daemon) and the auth/exposure
> posture — including the one the milestone headline depends on: what a
> Mac's Screen Sharing can actually speak to.

## Context — the seam survey (measured at `c4152178`)

Every fact below was read from the tree, not inferred. File:line refs
are the receipts; the VZ-boot receipts this card cannot capture on a
Linux VM are named in §"Blocked steps" and stay CI-verified.

### S1. The frame: seat-exclusive, 1280×720 BGRX

- The composited scanout is `virtio_gpu.gpu_fb`: 1280×720, B8G8R8X8_UNORM,
  3,686,400 bytes (`docs/hardware-contract.md` framebuffer-snapshot
  section; `user/go/vi/wmseat.go:43-47` `ScanoutWidth/Height/BPP/FbBytes`).
- The seat maps it writable via `vi.MmapScanout()` → `MmapHint(M33ScanoutTag,
  …)` (`user/go/vi/wmseat.go:92-97`) — the M33/ADR 0016 shared-anon seam.
- The bind is **seat-exclusive**: `wm_server.scanout_bind` returns 0
  unless `pid == wm_pid`, the registered WM seat
  (`kernel/src/wm_server.zig:438-444`; "the WM seat is the privilege").
  No other EL0 process can map the scanout. The frame lives in the seat
  process's address space — exactly as the card stated.
- Present is `vi.WmctlRequestPresent()` = slot 65 cmd 3
  (`user/go/vi/wmseat.go:76-79`); the seat's composite loop is paced by
  the kind-18 tick (`user/go/gotabwm/seat.go:265-303`,
  `EvCompositeTick = 18` at `user/go/vi/wmseat.go:51-54`).
- **No damage tracking exists**: `compositeTick` repaints whole frames
  (`user/go/gotabwm/seat.go:382-420`). An RFB server must diff frames
  itself (a 3.7 MB memcmp per frame is cheap; hextile/RRE are
  diff-friendly encodings — M84b's problem, not a seam problem).
- Host-side frame reads have one precedent: queue-4 kind-4 snapshots
  stream `gpu_fb` to the host (`docs/hardware-contract.md:320+`). It is
  host-side only — not usable by in-guest code.

### S2. Input: the seat drains kinds 19/21; synthesis is in-process

- `EvWmPointer = 19`: `arg0 = x|(y<<16)`, `flags` low byte = buttons,
  `arg1` = capture-time HID modifier byte (#2896; synthesized events
  forward 0)
  (`user/go/vi/wmseat.go:60-62`).
- `EvWmKey = 21`: `arg0` = HID usage, `flags` = ADR 0009 key flags
  (`user/go/vi/wmseat.go:65-67`).
- The seat drains them with `vi.PollEvent()` (slot 21) through
  `drainSeatEvents` → `consumeSeatEvent` → `handleWmPointer` /
  `handleWmKey` (`user/go/gotabwm/seat.go:298`, `:512-533`,
  `user/go/gotabwm/hid.go:501+`).
- Queue-3 kinds 1/2 carry **host→guest** HID injection (raw 8-byte
  keyboard / 5-byte pointer reports); the contract states injected
  reports go through `input.decode_keyboard_report` verbatim and land in
  the per-process event FIFO "when an app window owns focus"
  (`docs/hardware-contract.md:199-230`). That direction is host-operator
  → guest. There is **no EL0→EL0 input-injection syscall** — a separate
  RFB daemon process cannot inject into the seat's queue.
- Consequence: the only kernel-change-free injection point is
  **in-process synthesis inside the seat**: build a `vi.Event` with kind
  19/21 and call `consumeSeatEvent` — the exact function the hardware
  path uses. RFB PointerEvent maps to absolute x/y directly (1280×720);
  RFB KeyEvent needs the keysym→HID-usage table (M84b's deliverable —
  keysyms are X11 keysym *numbers*, a data table, not X11).

### S3. TCP: one system-wide connection, no loopback, listen exists

- `vi.Listen(port)` — slot 30 passive-open (`ip==0`) — is the inbound
  seam (`user/go/vi/conn.go:131-148`); proven by GOSSHD.ELF (M70g G1,
  default 2222, `user/go/sshd/main.go`) and GOHTTPD.ELF (M71l).
- The kernel TCP is a **single system-wide connection**: `owner_pid`
  (`kernel/src/tcp.zig:348-367`, `:497`). While the RFB server holds it,
  no other process (GOSSHD, fetch, DNS) can use TCP. This is a
  deployment constraint, not a blocker — recorded in D5.
- **No TCP loopback**: "an own-IP connect is refused `.no_peer`"
  (`kernel/src/tcp.zig:29`). A guest process cannot TCP-connect to the
  guest's own listen port. TCP-in-TCP tunneling inside the guest is
  impossible — this decides the tunnel shape in D6.
- Bounds: M84e raised `payload_max` from 192 to 1460 (one Ethernet MTU)
  after measuring the first-frame ACK latency. There is still one RX
  segment and no reassembly (`kernel/src/tcp.zig:59-69`).

### S4. Reachability: gates yes, real iron no (recorded negative)

- **Gates**: the runner's `--net-tcp-connect <ip>:<port>:<mode>`
  emulation is the host→guest TCP path; `live-ssh-server.spec` proves a
  guest listen (GOSSHD) against the runner's SSH-2 client, hermetic via
  `--net`. M84c's `live-rfb` gate inherits this topology.
- **Real Apple-VZ iron**: `--net-nat` gives the guest outbound NAT only;
  there is **no NAT port-forward, no runner host-listen bridge mode, and
  no guest SSH `-R`** (`user/go/ssh` has no remote-forward). A Mac cannot
  open a TCP connection to the guest today. This is a recorded negative,
  not a gap in the card: M84's gates stay hermetic; the real-device
  headline needs a named follow-up (§"Open issues").
- ADR 0025's Context 1 ("the only host→guest path today is the
  custom-virtio console") is therefore still true outside `--net`
  emulation; GOSSHD moved the *guest* side, not the reachability.

### S5. Trust toolkit (ADR 0024, unchanged)

- Principals `uid_system`/`uid_user`, caps; remote input is a privileged
  capability, not a courtesy (this card's brief).
- M50 TS4 replaced the M46 in-band secret with HMAC-SHA256/Ed25519
  challenge-response (`VIRELAIOS-AUTH/1`); the proven strong remote auth
  in the tree is **SSH-2 publickey via GOSSHD** (Ed25519 host key from
  `ssh-host-ed25519`, `SSH/AUTHORIZED_KEYS` — M70g G1, gated).
- M47 crypto is userland-Zig-only; there was **no DES** in the tree at
  this survey. M84e's host-only compatibility exception is recorded
  in D6; no DES enters the guest.

### S6. The fallback that was not needed (ADR 0016)

Had the frame seam been missing, the fallback was a snapshot-fed daemon:
the seat copies each presented frame into an ADR 0016 shared-anon region
(`handle_mmap_shared`, `kernel/src/shared_region.zig` /
`shared_mmap.zig` — owner-RW/peer-RO wiring exists, max 8 regions) and a
daemon serves it. Measured cost: a 3.7 MB copy per present, region
management, half-frame tearing sync — and input would *still* need the
seat's cooperation (a new WM_RPC message type), because cross-process
injection does not exist (§S2). Every seam the in-seat shape needs
exists; the fallback is recorded and **not taken**. No kernel change is
required by this milestone.

## Decision

### D1. Serving shape: in-seat. The server reads its own scanout and
### synthesizes its own events. It serves the composite; it never composes.

The RFB server runs in the GOTABWM.ELF seat process (as a module or
goroutine of the seat — M84c's placement call, not this ADR's):

- **Frame**: the seat's existing writable scanout mapping (§S1). Zero
  copy, zero new seam. Against ADR 0033: this is not a second
  compositor — the server *serves the composite the seat already
  produced* and never composites. The "no second compositor" line holds
  because no new present path, surface, or composition policy is added.
- **Input**: in-process synthesis of kind-19/21 `vi.Event` into
  `consumeSeatEvent` (§S2) — the same routing hardware input takes, with
  no kernel change. `drainSeatEvents` already takes the poll function as
  a parameter, so synthetic events can be interleaved with the hardware
  queue without forking the loop.
- **TCP**: `vi.Listen` in the seat process (§S3).
- **Rejected: snapshot-fed daemon** — §S6. More moving parts, a
  per-present 3.7 MB copy, and no benefit: the frame seam it works
  around is not missing.

### D2. Present/damage: the server diffs; the seat is the clock

No damage regions exist in the seat and none are added. The server keeps
the last-sent frame, memcmps per present (it *is* the presenter, so
present cadence is observed directly, not polled), and encodes the diff
with hextile/RRE (M84b). Full-frame updates on demand stay legal.

### D3. Remote input is a privileged capability — gated at the session,
### the seat, and the boot path

- **Session**: only events from an authenticated viewer session are
  synthesized. The authentication *is* the control (D6) — there is no
  weaker "courtesy" tier.
- **Seat**: the seat is the trust boundary. Its scanout mapping and
  event queue are already `wm_pid`-gated (§S1); remote input inherits
  exactly the local seat's authority — no more, no less. A viewer can do
  what the local user can do, because it *is* the local user's input
  path. This is stated plainly so no later card "discovers" extra
  privilege: remote input === local input, and the viewer is
  authenticated as the operator.
- **Boot path**: the RFB server is never on it. Explicit operator start
  only (GOSSHD precedent: "Not on the boot path",
  `user/go/sshd/main.go`). A boot that never starts RFB is byte-identical
  to today.
- **Teardown**: M84d owns client-death honesty (M52's bar) — a viewer
  dying mid-drag must not wedge the seat's input routing. The in-seat
  shape makes this *easier* (no cross-process state), not free.

### D4. TCP ownership: while serving, the seat owns the one connection

§S3's single system-wide connection means an RFB-serving seat and
GOSSHD/fetch/DNS cannot use TCP concurrently. Operational consequence:
the RFB server and the SSH server are never co-tenants of one boot in
M84 — the operator picks the remote-access mode per session. A later
card may multiplex (SSH-channel-plumbed RFB, §D6), but M84 does not pay
for it.

### D5. Reachability posture: hermetic gates now, named follow-ups for
### real iron

- M84b/c/d run against the `--net-tcp-connect` emulation (the
  `live-ssh-server` topology). The runner is the trusted peer; the link
  is hermetic.
- Direct real-device inbound ("a Mac opens a socket to the guest") is a
  recorded negative (§S4). The class-C tape has a host-side loopback
  bridge; production reachability remains a separate follow-up:
  1. **Host loopback bridge**: the M84d tape uses `rfbprobe -bridge`
     behind the runner's hermetic `--net-tcp-connect-stream` adapter.
     No guest or kernel change. **Trusted-local test path only**: the
     bridge binds 127.0.0.1, serves one same-machine viewer, and now
     authenticates it with a one-shot VNC password (M84e, D6).
     This is not a remote-access story.
  2. **Guest SSH `-R`**: the guest dials out (NAT allows it) and
     reverse-forwards; needs `-R` in `user/go/ssh` (does not exist).
- M84 claims nothing about direct real-device inbound. Its tape
  uses the host bridge (1); the hermetic gates remain independent.

### D6. Auth/exposure posture — the critical call

**On the guest RFB wire the server offers exactly one security type:
None (RFB 3.8 §7.2.1). The class-C Screen Sharing tape uses VNC
authentication (type 2) only on the host loopback bridge. "No
unauthenticated direct RFB" is enforced by exposure, not by the guest
wire.**

M84e amendment (#1835, 2026-09-28): the original claim that "macOS
Screen Sharing speaks None and VNC-password-auth on a standard
connection" was **inferred and false for None**. M84d observed on
macOS 27.2 (`artifacts/rfb-tape/m84d/runner.log`, quoted on #1835):

```text
seat->viewer "RFB 003.008\n"
viewer->seat "RFB 003.003\n"
seat->viewer 00 00 00 01 (None)
bridge closed: viewer->seat 12 bytes
gotabwm: rfb handshake refused
gotabwm: rfb drop handshake peer
```

Screen Sharing hung up before ClientInit and then prompted for a password.
The same result was observed against the codec on localhost without a VM.
The tape cannot use direct guest None. The chosen compatibility boundary:

- **Guest VNC password auth remains rejected.** DES-based VNC auth has
  an eight-byte password limit and is not a strong remote-auth control.
  The guest's server and M47 crypto keep DES out; the hermetic
  `live-rfb` wire and its 6/6 runs remain RFB 3.8/None.
- **Host bridge exception, type 2 only.** `rfbprobe -bridge` generates
  one random eight-character password for its single loopback viewer,
  speaks VNC auth to Screen Sharing (3.3/3.7/3.8), refuses bad type or
  password before guest bytes, then speaks 3.8/None to the guest. Only
  host Go `crypto/des` implements the legacy challenge response. The
  password goes to the operator, not the tape's captured runner log.
  This protects one same-user, same-machine demonstration, **not**
  routable remote access or confidentiality.
- **A custom challenge security type is rejected.** Screen Sharing
  would not speak it; the headline dies.
- **VeNCrypt/TLS is deferred** to a later card: it needs a Go TLS
  *server*, and M53 shipped a TLS 1.3 *client* only.

Why exposure-enforcement satisfies "no unauthenticated *direct* RFB":

- The server is never on the boot path (D3) and never bound for LAN
  exposure by default; the operator starts it explicitly per session.
- There is **no authenticated remote path in M84**, and this document
  does not claim one. D4 rules out guest-side sshd co-tenancy in a
  serving boot (one system-wide TCP connection); D5(1)'s VNC-authenticated
  bridge is loopback-only and is not an SSH tunnel. Remote use is
  **unsupported**
  until an authenticated transport exists (the SSH-channel-plumbed
  card named below, or a TLS-server card).
- What M84 does have: the hermetic `--net` gates (the runner is the
  trusted peer) and the VNC-authenticated trusted-local bridge
  (D5(1): 127.0.0.1, same-user) for the Screen Sharing tape. Both
  are same-trust-domain paths;
  neither crosses a network an adversary can reach.
- Binding the RFB listen to a routable network without the tunnel is an
  operator error the docs forbid — it is not a mode the server
  advertises, defaults to, or documents.

The strong path (later card, not M84): **SSH-channel-plumbed RFB**.
Measured constraint (§S3): the kernel TCP is a single system-wide
connection with no loopback, so TCP-in-TCP tunneling inside the guest is
impossible — "GOSSHD port-forward" can only mean the SSH server
accepting a tcpip-forward channel and piping it **in-process** to the
RFB codec. Therefore **M84b must write `user/go/rfb` transport-agnostic**
(byte-stream in/out, no socket assumptions), so the later card can plug
it onto an SSH channel without touching the codec. This is a
hard requirement on M84b, recorded here so the codec's shape is right
the first time.

### D7. What M84b/c/d inherit (binding)

- M84b: codec over an abstract byte stream (D6); raw + hextile + RRE;
  keysym→HID-usage table (X11 keysym numbers as data); fixtures pinned.
- M84c: in-seat server (D1); `live-rfb` gate on the `--net` emulation
  (D5); rfbprobe speaks plain RFB 3.8/None to the emulated peer — the
  gate proves the wire and the pixels, the ADR proves the posture.
- M84d: negatives + client-death (D3); the Screen Sharing tape is
  class-C, with the D5(1) bridge and M84e's host auth amendment on
  real iron — it is not M84's gate evidence.

## Consequences

- M84 needs no kernel change, no new syscall, no ADR 0007 amendment.
  The card's stop-and-report exit was not taken.
- GOTABWM grows a network server. The seat is already the trust hub
  (WM_RPC, hosted apps); the RFB module is still explicit-start-only and
  single-connection, and the seat's demo/live loop is untouched when RFB
  is not started.
- The auth story is honest about what it is: guest wire-None, host-bridge
  VNC auth only for the local tape, and no supported remote path.
  Any future reader who wants remote wire-level auth gets the
  SSH-channel or VeNCrypt/TLS card, not a guest DES revival.

## Rejected alternatives

- **Snapshot-fed daemon** (§S6): all cost, no benefit; the seam it
  routes around exists.
- **Guest VNC password (DES) auth** (D6): broken crypto and eight-byte
  passwords would downgrade the SSH-publickey remote-auth bar.
  The host-only loopback tape exception is not a remote control.
- **Custom Ed25519 challenge as an RFB security type** (D6): kills the
  macOS headline; Screen Sharing would not speak it.
- **TLS-wrapped direct RFB in M84** (D6): needs a Go TLS server; M53
  was client-only. Later card.
- **Cross-process input injection via a new syscall** (§S2): a kernel
  change this card forbids; in-seat synthesis covers it.
- **Offering `None` *and* documenting direct LAN use**: refused — the
  exposure posture (D6) is load-bearing, not decorative.

## Open issues (not M84)

1. A production host-to-guest reachability path. The `rfbprobe` loopback
   tape bridge is hermetic and does not enable direct remote access.
2. Guest SSH `-R` remote-forward (the pure-SSH real-device path).
3. Go TLS server (the VeNCrypt/TLS direct-RFB card).
4. SSH-channel-plumbed RFB (the D6 strong path; needs M84b's
   transport-agnostic codec + a tcpip-forward-capable SSH server).
5. A loopback-bind seam for slot 30, if the threat model ever needs
   bind-address enforcement instead of operational posture. Kernel
   change — deliberately not proposed here.

## Blocked steps / observed vs inferred (AGENTS.md)

- **Observed** (read from the tree at `c4152178`, refs in §Context):
  scanout geometry/format and seat-exclusive bind; event kinds 19/21 and
  their arg layouts; `consumeSeatEvent` routing; `vi.Listen` semantics;
  single system-wide TCP connection; no TCP loopback; `--net-tcp-connect`
  emulation; GOSSHD/GOHTTPD as listen precedents; no NAT port-forward,
  no runner bridge, no guest `-R`; no DES in the tree; no damage
  tracking; shared-anon fallback shape.
- **Observed later (M84d, #1835):** macOS 27.2 Screen Sharing replies
  3.3 and hangs up on security None before ClientInit (transcript in D6).
  The former inferred support for None is withdrawn. The host-only VNC
  auth exception is the M84e decision, not evidence of remote safety.
- **Inferred:** guest-side DES would be the wrong remote-auth trade
  (D6), a values call. The original M84a survey had not tested Screen
  Sharing; its security-type guess was not a result.
- **Original M84a blocked step:** VZ-boot probe receipts (frame address,
  present cadence, `--net` reachability) could not run on the Linux VM
  used for that survey. The seam *shapes* above were code-measured.
  M84d's later Screen Sharing transcript is a separate macOS 27.2
  observation, not retroactive M84a boot evidence.
- **Not blocked**: `go test ./vi/...` host suite — green on this VM
  (Go 1.24.7 toolchain, repo-pinned go1.27.0 downloaded for the module).
  No Go code was changed by this card (docs-only diff).
