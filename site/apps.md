---
title: The app fleet
parent: capabilities
status: published
tags: [capabilities, apps, userspace]
---

# The app fleet

VirelaiOS ships a real application suite, almost all of it Go EL0
binaries staged from the host share as `*.ELF`. The catalogue is
[`image/apps.txt`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/image/apps.txt),
baked into the image as `/host/APPS.TXT` — a versioned, additive schema
whose v2 rows declare fixed `argv=`, declarative `caps=`, `opens=` mime
types the app can be handed, and `selection=primary` opt-ins. Docked
rows appear in the launcher's rail grid; undocked rows launch by name
from the palette, a file's Open With menu, or the shell's `exec`. A row
that names an unstaged binary refuses honestly — "Binary not staged" —
and every launcher-visible app opens a window.

This page is the fleet by category. The seat that hosts them is
[[desktop]]; the runtimes underneath are [[programs]]; the media engines
several of them share are [[media]].

## Editors, files, and shell

The daily-driver core: two editors with deliberately different scopes,
a file manager, a terminal, and a shell that is one engine behind both
front-ends.

| App | What it is |
|-----|-----------|
| `GOEDIT.ELF` | The code editor — find/goto bars, an undo op ring, syntax-aware editing, themes, a minimap, bracket matching, build-diagnostics navigation (it is the face of the in-guest `GOBUILD` error list), and format-on-save. Owns the unsaved-changes dialog client the seat arms on `WIN_UNSAVED`. Gate: `go-edit`. |
| `NOTE.ELF` | The fleet's plain text editor — deliberately *not* an editor arms race: open, edit, `ctrl+s` save, auto-save on close when dirty. It is the manifest's `opens=text` default and the seat specs' canonical hosted tab. |
| `GOFILES.ELF` | The file manager — a real Bubble Tea model over the window-bound tty (not a widget app): list/open on the share, batch copy/move, trash + undoable delete, recent files, "Open With…" dispatch through the shared mime registry, drag-source/drop-target, spacebar **QuickLook** previews, and per-tab navigation history on the seat's nav kinds. Gate: `go-fileman`. |
| `GOTERM.ELF` | The terminal — named profiles (`term-profile` bundles font and palette keys and applies them live through the settings store), clickable OSC-8 hyperlinks, scrollback, selection, search, and the bound-tty surface every TUI shares. Gate: `go-term`. |
| `GOSH.ELF` | The shell — serial seat and hosted tab alike, backed by the pure-Go **`shlib`** engine it shares with GOTERM: pipes, redirection, slot-79 globbing, `cd -` and a directory stack, aliases, heredocs, history expansion (`!n`, `!!`, `!$`), contextual completion, `jobs`/`kill %N`/Ctrl-C job control, a `toolbox` multicall of builtins, SNTP `time sync`, and the `log`/`date`/`clip` readers. Gates: `go-sh`, `go-shell-polish`. |

## Productivity

Small, honest applications that behave like their desktop namesakes —
state serializes through the seat's save/restore hooks, so a snapshot or
a tab close does not lose the document.

| App | What it is |
|-----|-----------|
| `GOCALC.ELF` | Fixed-point decimal calculator plus a programmer mode (HEX/DEC/OCT/BIN, bitwise ops, shifts), history line, and a pad that shares its engine with the keyboard. Gate: `go-calc`. |
| `GOSHEET.ELF` | A CSV spreadsheet — a 128×64 virtualized grid behind a `TableController`, an edit line, formulas, a menu bar, typed `text/csv` copy/paste, and crash-safe CSV import/export through the shared FilePicker. Gate: `go-sheet`. |
| `GOPAINT.ELF` | A paint app — brush, line, rectangle, flood fill and eraser over a fixed 16-colour palette, an undo ring, QOI save/open and PNG export. Gate: `go-paint`. |
| `GOREADER.ELF` | The document reader — the `opens=document` handler that renders PDFs through the bounded engine in `user/go/pdf` ([[media]]), with page navigation, zoom, find, and session state. Gate: `go-reader`. |
| `GOCLOCK.ELF` | Clock — World / Stopwatch / Timer / Alarm tabs multiplexed onto the kernel's one app timer; alarms persist and late-fire on start. Gate: `go-clock`. |
| `GOEMOJI.ELF` | The emoji picker — `ctrl+shift+e` summons it from anywhere; pick a glyph from the grid, compose-pair, or kaomoji tables and it pastes into the previously focused tab. Gate: `go-emoji`. |
| `GOVAULT.ELF` | A secrets store — one unlock-gated vault file (PBKDF2-HMAC-SHA256 → AES-256-GCM, crash-safe writes), masked entry fields, expiring copies through the primary selection, an idle lock, TOTP codes, and its own plaintext audit + receipts face. Gate: `go-vault`. |
| `GOIRC.ELF` | An IRC client — the RFC 1459/2812 core plus channel list, scrollback and mentions; TLS by default (`tls.Dial`, 6697-style), and plaintext refuses unless `--plain` sets the session's consent bit. Gate: `go-irc`. |

## System

The desktop's own maintenance surface — the panel, the monitor, the
viewer, the snapshot and self-test tools, and the first-boot tour.

| App | What it is |
|-----|-----------|
| `GOTOP.ELF` | The process monitor — live procs tab with click-to-kill and real CPU%/MEM columns, a GPU tab reporting the compute device's busy/queued/submit counters, and a Trust tab tailing grant decisions and audit receipts. Gate: `go-top`. |
| `GOSET.ELF` | Settings — edits the schema-v2 `SETTINGS.TXT` the seat and kernel read (writes are crash-safe publishes), hosts the **grants consent** pane for signed `ReleaseCaps`, the shortcuts view of the chord registry, font-size and palette pickers, and per-app grant rows. Gate: `go-settings`. |
| `GOVIEW.ELF` | The multi-format image viewer — QOI/PNG/JPEG/GIF/SVG through the shared decoder, zoom and pan, GIF playback with per-frame delays and a space-bar pause, and the `opens=image` default. Gate: `live-image-viewer`. |
| `GOSNAP.ELF` | Snapshots — list/save/restore/delete named machine images parked on the share, with a two-step consent arm; also reachable as the PWR Snapshot row. Gate: `go-snap`. |
| `GOSELF.ELF` | The guest self-test — runs in-OS cases and writes receipts the host byte-compares; the standing proof that EL0 file, window and misc ABI behave. Gate: `go-selftest`. |
| `GOWELCOME.ELF` | The first-boot tour — five core gestures plus one-click launchers. |
| `GOHELP.ELF` | The help browser — a Bubble Tea model over the bound tty that walks the staged `/host/docs` bundle. Gate: `go-help`. |
| `PULSE.ELF` | A Charm TUI system monitor — a real `tea.Model` fed by the kernel's bound-tty queue and repainted on a 1 Hz tick. |

## Network

The clients and the one server. The diagnostics are pure shell tools —
no manifest row, driven from `exec` — while `GOHTTPD` is the passive
open that serves the share outward.

| App | What it is |
|-----|-----------|
| `GOHTTPD.ELF` | The in-guest HTTP/1.1 **and** HTTPS server — one passive-open port (8080 cleartext, 8443 TLS with the in-tree TLS 1.3 server half), keep-alive connections, serial per-connection serving of the share. Gate: `live-httpd`. |
| `GOFETCH.ELF` | The HTTP(S) client — windowed `https://` fetch over in-process TLS, a console cleartext mode, and `--download` saving the body to the share; `expect-fail` legs pin name/expired/chain refusals closed. Gate: `go-fetch-https`. |
| `GOPING.ELF` | ICMP echo — including `ping6` on the IPv6 datapath. |
| `GONETSTAT.ELF` | The network dashboard over the net-stats snapshot seam. |
| `GODNS.ELF` | Bounded RFC 1035 lookup (A records; no cache). |
| `GOTRACEROUTE.ELF` | Direct-peer ICMP reachability diagnostics. |

The net CLIs share one gate: `go-net-clis`.

## Sound

Audio is real in both directions — playback out through virtio-snd and a
bounded capture stream back in.

| App | What it is |
|-----|-----------|
| `GOSOUND.ELF` | The sound player — streaming RIFF/WAVE (PCM, float, ADPCM) resampled by a 16-tap sinc into the negotiated tuple, with record and live mic-meter modes sharing the one capture stream. Gates: `live-sound-playback`, `live-sound-record`. |
| `GOREC.ELF` | The recorder — `record <seconds> <out.wav>` captures S16/48 kHz/mono and publishes a crash-safe WAV the host recomputes byte-for-byte; a bare launch opens the windowed view. |

## AI

A small local language model running on the Metal GPU's bounded compute
device — not a network call, not a demo stub.

| App | What it is |
|-----|-----------|
| `GOINFER.ELF` | The inference CLI over `user/go/infer` — a VIW model image (owner-approved SmolLM2-135M, Apache-2.0) loaded into sealed weight buffers, with a greedy argmax decode that is deliberately deterministic: the same tokens every run. Legs in `live-gpu3d`. |
| `GOASSIST.ELF` | The chat front-end — streams the engine's tokens into a windowed conversation view, persists transcripts under `ASSIST/` crash-safe, and round-trips an open thread through save/restore. Gate: `go-assist`. |

## Web

`WEB.ELF` is the browser — the app shell (chrome, navigation, fetch) in
Go over the project's own `webrender` engine. It is a deliberately
**Dillo-tier subset**: HTML parse → bounded CSS cascade → box layout →
native paint, HTTP/1.1 keep-alive with chunked and gzip bodies, and
**no JavaScript** — that refusal is permanent (ADR 0028). The product
surface is real: a history dropdown, bookmarks, find-in-page, per-tab
zoom tied to the `font_size` ladder, downloads with cancelable progress,
and form fields — all pinned by an exact-RGB8/SHA-256 live-web
comparator that renders real pages against a host reference
(`live-web`, with `live-web-ttf` pinning font resolution). Downloads of
a PDF dispatch to GOREADER rather than navigating.

## Development

The guest builds the guest: the toolchain, the diff, the SCM, the
store, and the agent channel.

| App | What it is |
|-----|-----------|
| `GOBUILD.ELF` | The in-guest build driver — walks a bounded import graph, generates `-importcfg`, and execs the guest's own `cmd/compile`/`cmd/link`; `fleet` builds the pinned app set and `test` runs the package suite, with named refusals (`dep_unsupported`, `closure_too_large`). Gate: `live-gobuild`. |
| `GODIFF.ELF` | A unified context diff — and the self-host capstone: it was authored in GOEDIT, compiled by GOBUILD, run, committed and pushed by FLINT entirely in-guest. `-i` opens an interactive side-by-side viewer. Gates: `go-godiff`, `live-godiff-loop`. |
| `FLINT.ELF` | The agent-native SCM — files become Atoms, staged Ops form signed Changes on Streams (Ed25519), a semantic three-way merge, and FLINT-SYNC/1 (`clone`/`pull`/`push`/`ls-remote`) against a host `flintd`. Gate: `go-flint`. |
| `STORE.ELF` / `GOSTORE.ELF` | The install seam and its GUI — `ls`/`install`/`remove`/`update`/`rollback` re-authenticate the signed release manifest, sha256 the fetched ELF, publish through WriteFileSafe with a `.prev` rollback target, and stand an install-time consent modal. GOSTORE browses the signed catalog in a tab and drives the same legs in-process. Gate: `go-gostore`. |
| `AGENTD.ELF` | The agent control channel — JSON Lines on guest TCP 4747 behind an Ed25519 challenge, verbs from `proc.list`/`fs.read` to `ui.windows`/`ui.input`/`gosh.run`, fail-closed and audited. Gate: `go-agentd`. |

## Games

| App | What it is |
|-----|-----------|
| `GOMINE.ELF` | Minesweeper — three seeded board sizes, first click always safe, flood-fill reveal, flagging, chording, and a mid-game state that survives the seat's snapshot/restore. |
| `GOSOL.ELF` | Solitaire — a full Klondike table on the seat, same snapshot discipline. |
| `GOSTALGIA.ELF` | The ported Gostalgia TUI environment — an entire foreign Go userland (apps, services, shell over IPC) shipped as one static ELF; see [[programs]]. |
| DOOM | It runs Doom — **as a signed STORE payload**. The GPL engine lives in its own sibling repository (`doom-engine`), is built there into a freestanding ELF, and installs through STORE with a hash-pinned `doom1.wad` — the ADR 0058 carve-out that keeps GPL out of this tree. `live-doom` plays a scripted E1M1 demo to `I_Quit`. |

<Aside kind="note">

**VERIFIED.** Every row above is pinned by a declarative gate — the
`go-*`/`live-*` spec names beside each entry are `just gate <id>`
targets, not aspirations. The manifest schema itself is pinned by
`go-wm-default` (dock decode), `go-dogfood` (launcher row → window),
and a host test that fails any row which cannot open a window.

</Aside>

<Aside kind="warning">

**LIMITATION.** The fleet is bounded by design: the editors are not
LSP clients, the browser runs no JavaScript, the sheet is CSV only, and
a pure-CLI tool has no launcher row by policy — the shell's `exec` is
its face. Retired Zig predecessors (`CALC.BIN`, `NOTEPAD.BIN`, `TOP.BIN`,
`DESKTOP.BIN`, `EDIT.BIN`, and friends) were deleted one card at a time
as their Go successors went green; `TABWM.BIN` is the deliberate
exception, retained as the fallback seat.

</Aside>
