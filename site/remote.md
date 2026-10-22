---
title: Reaching the machine
parent: machine
status: published
tags: [machine, remote, ssh, rfb, agentd]
---

# Reaching the machine

There is no routable path into a VirelaiOS guest by default — no NAT
port-forward, no host-listen bridge, and no guest loopback. That is a
recorded negative, not a gap in the docs. Everything on this page is
therefore one of two shapes: **the host runner reaches in** through its
own hermetic channels, or **the guest deliberately opens a door** —
explicitly armed, behind a credential, and honest about exactly what it
does and does not provide.

Four surfaces exist today: the hardened serial-console bridge, the SSH
surface in both directions, an in-seat remote-framebuffer server, and
AGENTD — the control channel built for programs, not people.

## The serial console over TCP: `--console-tcp`

The simplest door is the runner's own console bridge.
`--console-tcp [host:]port` serves the guest's virtio-console serial
stream on a real TCP socket — byte-for-byte the same stream `--console`
bridges to a terminal. Raw bytes, no telnet negotiation: `nc`, `telnet`,
or `socat` all work, and a terminal client may need `--crlf` since the
guest accepts either CR or LF.

The bridge is deliberately one client at a time, and deliberately
hostile to abuse. While a client holds the seat, every further
connection is answered `console-tcp: busy` and closed — no backlog
limbo, and the refusal is observable. A client that does not answer the
authentication challenge within 10 seconds is dropped with
`console-tcp: auth timeout`. More than 1024 bytes without a newline —
four times the guest line editor's bound — is refused with
`console-tcp: line too long`, the client dropped, and nothing of the
offending read forwarded. A client that stops draining guest output is
dropped at the socket's two-second send timeout rather than allowed to
stall the tee; TCP keepalive catches a peer that vanishes without a FIN.

Teardown is honest too: a client that disconnects mid-line gets a `0x03`
(Ctrl-C) written into the guest serial input, so the line editor echoes
`^C` and clears — the next client starts at a clean prompt instead of
inheriting a zombie partial line.

Authentication is the `VIRELAIOS-AUTH/1` HMAC challenge-response. The
secret comes from the `[host:]port:secret` spec or — preferred, because
it never appears in a process list — `--console-tcp-secret-file <path>`,
which reads the first line of a file. The inline form is mutually
exclusive with the file form and warns on stderr. The default bind is
`127.0.0.1`; `0.0.0.0` exposes the bridge to the LAN and is the
operator's explicit choice. The MAC compare is constant-time, and the
secret text is never echoed into any log line.

<Aside kind="info">

**LIVE-GATED.** `live-console-tcp` and `live-remote-console` drive real
clients through the bridge — including the busy refusal, the mid-line
`^C` cancel, the over-long line drop, the wrong-secret `auth failed`,
and the guarantee that the secret itself never reaches runner output.

</Aside>

For an actual operator workflow, `tools/remote-terminal.sh` wraps the
bridge into a persistent serial-only GOSH service: `serve` keeps a VM
running against a dedicated share, and `attach` connects over the same
`--addr`/`--secret-file` client contract — locally, or through host
OpenSSH. The supported remote-product boundary is **host OpenSSH → host
interactive client → loopback HMAC bridge → guest GOSH**: SSH supplies
confidentiality between machines, the HMAC bridge supplies operator
authority at the console, and the wrapper keeps its random mode-0600
secret outside the guest share entirely. Ctrl-C cancels the guest line,
Ctrl-] disconnects only, and `monitor` hands back the raw kernel
monitor.

## The guest's own shell door: GOSH `net`

One level up from the serial bridge, the guest can host a real remote
shell itself. `GOSH.ELF net <port> [open]` attaches the NET front-end —
the terminal seam's selector 3 — and passive-opens a guest TCP listener
(the default port is 2323). The kernel pumps raw bytes between the
terminal rings and the connection, and the arriving session *is* GOSH:
full line editing, history, pipes, builtins.

Authentication composes with the listener. With no mode argument the
front-end answers the `VIRELAIOS-AUTH/1` challenge and requires the
client to answer with `HMAC-SHA256(secret, challenge)` from the
`net-hmac` secret row — the same delegated challenge-response the
console bridge uses. `open` is the explicit insecure mode, named
insecure, and exists because a refusal-to-listen default is the correct
posture for a door. A disconnect auto-detaches the terminal.

<Aside kind="info">

**LIVE-GATED.** `live-remote` boots GOSH on the NET front-end and has
the host initiate the inbound handshake through the runner's hermetic
`--net-tcp-connect` — the only host→guest TCP path that exists.

</Aside>

## SSH — both directions

ADR 0025 pins a single modern profile for everything SSH in the system:
SSH-2.0 with `curve25519-sha256` key exchange, `ssh-ed25519` host keys,
`chacha20-poly1305@openssh.com` as the AEAD cipher, and `publickey` user
authentication — exactly one of each negotiation list, so interop is
honest and the parser stays small.

**Guest → host** is `GOSSH.ELF`, the userland SSH-2 client (the earlier
Zig client was retired; the Go one is what ships). It speaks the full
profile — real handshake, real host-key verification against pinned
`SSH/KNOWN_HOSTS` entries, `publickey` auth from a slot-70 Ed25519 seed
— and it interoperates with actual OpenSSH: the runner's
`--net-tcp-respond :relay` mode byte-forwards the hermetic stream to a
real upstream `sshd`, so the guest's client negotiates with the
reference implementation, not a mock.

**Host → guest** is `GOSSHD.ELF`, an in-guest SSH-2 server listening on
port 2222. It authenticates `publickey` against the share file
`SSH/AUTHORIZED_KEYS`, holds its host key in an app-bound
`ssh-host-ed25519` secret row, and pipes each `exec` request to
`GOSH.ELF -c` — one command per channel, output captured and returned
with the exit status. A `pty`-request plus `shell` shape also exists for
interactive sessions. GOSSHD is not on the boot path; the operator
starts it, and every missing precondition — no host key, no
authorized-keys file — prints one marker and exits before the listener
binds. Fail closed, never a fallback to open access.

<Aside kind="info">

**LIVE-GATED.** `live-ssh-server` runs the runner-hosted SSH client
against GOSSHD end to end; `live-ssh-endpoint`, `live-ssh-packet`,
`live-ssh-negative`, and `live-ssh-nocred` pin the client side, the
wire, the refusal paths, and the missing-credential posture.

</Aside>

## Remote framebuffer: RFB 3.8, in-seat, opt-in

The seat can serve the composited desktop itself. Started explicitly —
`GOTABWM.ELF --rfb-hermetic`, never on the boot path — the Go seat binds
a guest listener and speaks RFB 3.8 (the VNC wire protocol) with
security type **None**, serving one viewer at a time.

The placement is the design, not an accident. The scanout mapping is
seat-exclusive — only the registered WM seat may map the framebuffer —
and there is no cross-process input-injection syscall. So the RFB
server lives *inside* the seat: it diffs the seat's own composite on
every present (no damage tracking exists, so the server keeps a
last-sent frame and memcmps) and synthesizes remote pointer and key
events through `consumeSeatEvent` — the identical function hardware
input takes. A viewer can do what the local user can do, because it *is*
the local user's input path; that is stated plainly so nobody later
"discovers" extra privilege.

Every session end names its drop reason on the serial log —
`gotabwm: rfb drop <reason>` — and a viewer that dies mid-drag gets its
held press released at its last point before local input routes again.
Over-cap connections are refused with an RST in their own bounded slot,
not silently swallowed.

The wire itself offers only `None`, and that is load-bearing. macOS
Screen Sharing was observed to hang up on a None handshake and demand a
password, and guest-side VNC password auth is DES — rejected crypto that
never enters the guest. The compatibility story lives on the host side:
`tools/rfb-tape.sh` bridges one loopback viewer through the runner's
hermetic `--net-tcp-connect-stream`, speaks VNC auth type 2 with a
one-shot random eight-character password to Apple's viewer, and
translates the guest's hextile into Raw — the encoding Screen Sharing
actually accepts. With `--type-password`, the tape answers the viewer's
own password sheet through System Events so an unattended run can
finish the handshake. Native macOS Screen Sharing then completes the
full tape: `VNC auth accepted` → `ClientInit shared=1` → frames.

<Aside kind="info">

**LIVE-GATED.** `live-rfb` drives a real probe viewer through the
hermetic transport — handshake, frames, input — and pins the negatives:
refused auth, oversized message, wedged viewer, and a viewer RST
mid-drag, mid-update, and mid-focus.

</Aside>

<Aside kind="warning">

**LIMITATION.** Hermetic and loopback only. There is no routable inbound
path to the guest — the Screen Sharing story is a same-machine bridge,
not remote access. ADR 0045 designs the authenticated transport (RFB
carried inside an SSH channel terminated by the seat, the `ssh -L`
shape) for when a reachability card lands; until then, direct RFB/None
on a routable socket is refused in every posture.

</Aside>

## AGENTD — the channel for programs

`AGENTD.ELF` is the control channel built for agents rather than
people — think an MCP tool server, not a remote desktop and not an
in-OS agent. It serves newline-delimited JSON on guest TCP port **4747**
behind an HMAC-SHA256 challenge, and the reference host client is
`tools/agentctl/agentctl.py`, a stdlib-only Python client that doubles
as the gate harness.

The wire is JSON Lines, flat objects only: `{"id":N,"verb":"proc.list"}`
in, `{"id":N,"ok":true,"result":{…}}` or a named error out. Requests are
handled strictly in order, line bounds tighten before auth (256 bytes)
and relax after (8 KiB), and the grammar is hand-rolled —
`encoding/json` never enters the guest because it would blow the ELF
size ceiling.

The verbs, gated individually:

| Verb | What it does |
|------|--------------|
| `proc.list` / `proc.get` | The kernel process table: pid, name, state, exit status |
| `fs.read` / `fs.write` | Whole-file reads and atomic writes, confined to flat names in the `/host/AGENT/` sandbox, ≤4096 bytes |
| `ui.windows` | Which windows the seat's strip holds — indexes, titles, focus, pin/freeze state |
| `ui.input` | Inject key and pointer events into the focused pane — requires the `input` cap, refuses `agent_input_no_focus` on a mismatch |
| `ui.screenshot` | Read the scanout through the bounded slot-88 copy — a 160×90 thumbnail or the full 1280×720 frame in RGB565, rate-bound |
| `ui.geometry` | Query, move, and split-settle a window the way the seat arranges it |
| `gosh.run` | Run one GOSH line and read back its output — the escape hatch from the sandbox, opt-in only via `--allow-exec` |

The posture is fail-closed at startup, before the listener ever binds:
the daemon must be `uid_user` with zero caps, the `agent-hmac` secret
row must exist, the `/host/AGENT/` sandbox must be listable — or one
named `agentd: refuse <reason>` marker and exit 1. There is no open
mode. The handshake is a fresh 32-byte challenge per connection,
answered under a domain string distinct from the console's and the ctl
channel's, so a MAC captured anywhere else can never answer this
server. A wrong answer closes with `auth_failed`; the session dies at
60 seconds idle. The daemon's reach ends where the kernel's trust model
ends — `gosh.run` can touch everything a `uid_user` process can, which
is why it alone is flag-gated.

<Aside kind="info">

**LIVE-GATED.** `go-agentd` proves every verb red and green — the auth
matrix, the sandbox, the refusal names — plus `live-agent-loop` for the
end-to-end agent-driven journeys.

</Aside>

## The agent-native desktop

ADR 0052 takes the next step: agents stop being "the agent" and become
first-class principals. A public keyring file `AGENTS.TXT` on the share
carries rows `agent=<id> key=<pub> caps=<csv>` plus `revoked=<pub>` —
world-readable, `uid_system`-owned, unforgeable in-guest. The private
half never enters the guest at all. Capabilities are declared per agent
from the same `caps=` vocabulary the app manifest uses, a missing cap
is a named refusal rather than a silent denial, and every verb —
allowed or refused — leaves a MAC'd audit receipt on the share for the
seat's companion lane and the host's inspector to read.

On top of identity sits the agent-view seat and third-party agent
apps: agents can drive the real desktop — `live-agent-loop` walks a
host-side agent through authoring, versioning, and shipping a guest
program using nothing but AGENTD verbs — while their sessions stay
attributable, capped, and revocable. The arc landed with a caveat on the
ledger: the gates are green, and the reference-host K-run plus owner
sign-off is the remaining step — read `docs/status.md` for the current
posture rather than a date-stamped claim here.

## Multi-VM host windows

One runner process can host several machines at once. The Machine
menu's **New Window for Profile** submenu lists the sibling `.virelaivm`
bundles in the profiles directory and boots each in its own session
window; a bundle that is already live drops out of the submenu, and a
dispatch that tries it anyway receipts `profile_in_use`. Sessions are
tracked through a registry that gives every window its own HostCommand
bus and its own HostInt lanes, so dispatch receipts name their target —
`host-ui: cmd=<verb> vm=<n>` — and the menu bar's shared verbs act on
whichever machine is frontmost. Headless, the same `new-window` verb
rides `--host-cmd-after <marker>:new-window@<path>` with an optional
`vm<k>:` marker binding to aim a trigger at a specific session's serial
stream.

## Read next

- [[machine|The machine]] — profiles, suspend, snapshots, self-update.
- [[host-int|Host integration]] — the VHI1 lanes and the ctl channel
  under the same glass.
- [[run|The runner reference]] — `--console-tcp`, `--net-tcp-connect`,
  and the rest of the surface, flag by flag.
- [[trust|Trust & isolation]] — the secrets store, app-bound
  credentials, and the capability model every door above defers to.
- [`docs/decisions/0022-remote-console.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0022-remote-console.md),
  [`docs/decisions/0025-ssh.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0025-ssh.md),
  [`docs/decisions/0037-remote-display.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0037-remote-display.md),
  [`docs/decisions/0044-agent-control-channel.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0044-agent-control-channel.md)
  — the binding ADRs.
