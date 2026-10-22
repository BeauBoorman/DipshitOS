---
title: Roadmap & status
status: published
tags: [roadmap, status]
---

# Roadmap & status

This page summarizes the milestone plan. The repository's
[`docs/status.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/status.md)
is the canonical, always-current source; this is the readable summary.
Issue numbers link the ledger to the tracker; gate ids name the standing
proof (see [[evidence]] and [[live-gates]]).

## Shipped

| Milestone | What landed |
|-----------|-------------|
| 0–2 | Boot pipeline, kernel handoff, `ExitBootServices`, identity-map MMU, polled serial console |
| 1.5 | The interactive `virelai>` monitor: shell, filesystem, reboot/shutdown |
| 3 | Allocator, GIC + timer, scheduler, EL0 + syscalls, uaccess, address spaces, exec |
| 4 | Entropy/ChaCha20 + ASLR, general filesystem, process registry, IPC, wait, kill, scale |
| 5 | Networking N1–N11: net TX/RX, ARP, IPv4/ICMP, UDP, the UDP syscall seam, NAT, DHCP, DHCP renew, TCP, TCP retransmission |
| 6 | Graphics G1–G6: framebuffer, text, Road Pops, Driving Award, the draw/window syscall seam |
| 7 | Input I1–I3: XHCI transport, USB enumeration + HID, the event FIFO + keycode decode |
| 8 | Usability U0–U8: ADR 0008 HIG, grouped `help`, line editing + history, the one error contract, window chrome (focus rings + title bars), `welcome`/`about`/`motd`, `sysinfo`, persistent settings on disk |
| 9 | Events E0–E6: per-process event queues, keyboard/pointer/window events to focused EL0 apps, `sys_poll_event`/`sys_wait_event` (slots 21/22), `KEYTEST.BIN` |
| 10 | Files & storage F0–F4: ADR 0010, per-process file table, initial `/esp/` + `/data/` routing (later replaced by the host-backed `/host` API), file syscalls (slots 23–27), the original `SAVETEXT.BIN`/`TYPE.BIN`/`DIR.BIN` demos (retired M78c; live storage coverage uses GOSH/GOFILES) |
| 11 | Desktop platform A0–A5: ADR 0011, the zero-heap `ui.zig` toolkit, the original `CALC.BIN`/`NOTEPAD.BIN`/`TOP.BIN`/`DESKTOP.BIN` programs (retired to Go — the current seat and clients are `GOTABWM.ELF` and the Go ELFs), `sys_exec`/`sys_kill` (slots 28/29) |
| 12 | Network apps N0–N3: TCP syscall seam (slots 30–33), RFC 1035 DNS, the original `TCP.BIN`/`GOFETCH.ELF`/`CHAT.BIN` programs (the Zig clients are retired; product clients are now Go ELFs) |
| 13 | Files & applications B1–B4: mutating filesystem seam (B1, slots 34–37), `APPS.TXT` identity manifest (B2), graphical data browser (B3; now `GOFILES.ELF`), and manifest-driven desktop composition (B4) |
| 14 | Shared user services S1–S4: the clipboard (slots 38–39), app timers (slots 40–41), the NOTEPAD composition capstone, and security/isolation hardening (the TCP owner fix + the hostile-EL0 gate) |
| 15 | Audio A1–A4: virtio-snd transport, PCM playback + `beep`, the EL0 audio seam (slots 42–45), `JINGLE.BIN`, the boot chime, and `CHIME.BIN` |
| 16 | Kernel consolidation C1–C4: multi-segment user images, guard pages + per-segment permissions, measured pools, one-session composition |
| 17 | Desktop completeness C1–C10 + Arc1–5: widget depth, window management, app upgrades, rich interactions, system polish |
| 18 | Terminal & shell depth: scrollback, selection, search, persistent history, colors, scripting mode |
| 19 | Shell as a programming environment: pipes (slots 56/57), redirection, env vars, functions + args, substitution, arithmetic, conditionals |
| 20 | Text rendering & Unicode: font sizes, Unicode glyphs, search, chrome, tabs |
| 21 | Window management depth: tiling, master-detail, minimize, alt-tab, notification center, maximize, focus rings |
| 22 | Developer tools: ELF loader, assembler, symbols, disassembler, strace |
| 23 | The text editor: `EDIT.BIN` with undo/redo, goto, tabs, syntax, console split — since retired to Go (`GOEDIT.ELF`, `NOTE.ELF`) |
| 24 | CALC grows up: programmer mode, memory, units, constants, history persist |
| 25 | File manager depth: du, sort, overwrite/conflict, path copy |
| 26 | Network experience: ping, netstat, traceroute, HTTP fetch display, offline preflight |
| 27 | Desktop polish & completeness G1–G30 (issues #444–#473): splash, wizard, about, previews, sounds, sysmon, tooltips, audits, dogfood |
| 28 | SMP: a second CPU core via PSCI, per-core schedulers, spinlocks, GICv3 IPIs |
| 29 | VM depth: demand paging, copy-on-write, anonymous `sys_mmap`/`sys_munmap` (slots 63/64) |
| 30 | Dynamic linking: freestanding `LD.SO`, `LIBUI.SO`/`LIBFONT.SO`, W^X multi-aperture isolation |
| 31 | Dynamic linking ecosystem: `CALC.ELF`/`NOTEPAD.ELF`/`FILE.ELF`/`DESKTOP.ELF`, `dlopen`/`dlsym` |
| 32 | Window-manager server migration (Seam A): desktop policy moved to a userland WM server (slot 65), the kernel slimmed WMS1–WMS9 |
| 33 | Seam B full pixel ownership: shared-anon mmap, apps own their buffers, the WM composes one present |
| 34 | FAT-free storage: the host file channel HF1–HF7 over custom-virtio; FAT removed; CLONE dedup |
| 35 | WASM core interpreter: `WASM.BIN`, a frozen `env.*` surface, the `wc` capstone |
| 36 | Skipped — the raster/wallpaper/viewer scope re-landed under later arcs (M78, M85, M89, M90) |
| 37 | Desktop quality pass: God Menu overlay, tab strip render + mouse, design tokens, snap guides |
| 38 | Vector typography: TrueType Inter/Fira Code, anti-aliased BGRA blending, proportional metrics |
| 39 | Tabbed desktop & modular UI: modular `ui.zig`, `TABWM.BIN`, tab lifecycle, viewports |
| 40 | Gate-fleet consolidation (#934) — a tooling workstream, not a product milestone |
| 41 | Test separation: parallel `zig build test`, shared mocks, de-monolithized sources |
| 42 | The Sexiburger desktop: mascot raster, the WM→app resize seam, `lib/tabapp.zig`, UX hardening round 2 |
| 43 | Device depth: the XHCI bulk engine, USB mass storage (BOT+SCSI), the `.usb` block seam |
| 44 | The terminal (vt) seam: `/dev/tty`, `sys_tty_attach` (slot 67); ADR 0020 |
| 45 | Userland shell & front-ends: the `tty.zig` editor, the original `SH.BIN`/`TERM.BIN` (both since retired to Go), the default-shell flip; ADR 0021 |
| 46 | Remote access Stage 0/1: `--console-tcp`, guest net auth (RC0–RC4); ADR 0022 |
| 47 | Crypto primitives: SHA-256/512, HMAC, ChaCha20, Ed25519; ADR 0023 |
| 48 | Browser-style tab depth: reopen/duplicate, reorder, pin/group, start surface, per-tab history, preview |
| 49 | A shell I'd use daily: `monitor` detach, the startup contract, the `toolbox.zig` multicall |
| 50 | Trust & isolation: uid/caps, permissions, secrets, authenticated remote, privilege gating; ADR 0024 |
| 51 | SSH: a userland SSH-2 client with real-OpenSSH interop (the Zig client was later retired); ADR 0025 |
| 52 | Client-death hardening: exit/revoke teardown pinned end to end — no zombie windows, stale mappings, or stuck captures |
| 53 | TLS 1.3 client + trust store: HKDF/SHA-384/AES-GCM, X.509 chain validation, real interop against four peer implementations; git-over-https followed; ADR 0029 |
| 54 | Go carries its first app: `GOWIN.ELF` owns a raw window, `WEB.ELF` renders in-guest; kernel untouched |
| 55 | The language split (ADR 0030): Zig keeps the kernel and the seats; new userland is Go |
| 56 | Finish the Go SDK: `vi` IPC + discovery, the WM_RPC wire, `widgets`, `tabapp` (gate `go-tabapp`) |
| 57 | `GOTABWM.ELF` as a second seat: it registers the slot-65 seat, manages its own windows, and hosts unmodified Zig apps over WM_RPC |
| 58 | Move the apps you touch: files, GOEDIT, GOTERM, fetch, FART re-land as Go ELFs |
| 59 | Default flip: a boot autostarts `GOTABWM.ELF`; `settings set wm tabwm` keeps the Zig fallback reachable |
| 60 | Starve Zig EL0: no new `user/src/*.zig` apps; the deleted Zig clients (`EDIT.BIN`, `FILE.BIN`, `CALC.BIN`, `NOTEPAD.BIN`, `SH.BIN`, and friends) went as their Go successors landed |
| 61 | Guest self-test: `GOSELF.ELF` runs in-OS cases; the host only byte-compares receipts |
| 62 | GOTABWM depth: in-process tab strip, constrained pane split, `.tabs` v2 session persist, pin/reorder, GOEDIT and GOCALC as hosted clients |
| 63 | GOTABWM HID: the seat drains kind 19/21 input — pin, Alt+Tab, real typing into GOEDIT |
| 64 | Signal: a green fleet plus EL0 exec caller survival |
| 65 | Go threads (ADR 0027): slots 73/74, a 16-task ceiling |
| 66 | Go owns files: honest HF error names, fsync at EL0 (slot 77), crash-safe settings, `NOTE.ELF` becomes the fleet editor |
| 67 | Go owns net: `vi` Dial/Send/Recv + DNS, in-process HTTPS for GOFETCH/GOTGIT/WEB |
| 68 | Go owns the shell: `GOSH.ELF` is the serial/login seat; `SH.BIN` was deleted; `TABWM.BIN` was retained by decision (ADR 0034) |
| 69 | Daily-driver floor: Go-seat dogfood, chrome cohesion, the edit→build→run loop |
| 70 | Moonshots: the web fidelity corpus, hardened `--console-tcp`, measured cross-process VZ save/restore, the `GOOS=virelai` port reaching in-guest `cmd/compile`+`cmd/link` |
| 71 | Seat honesty: the Go seat stops lying — hosted GOSH paints, M48 tab depth lands on GOTABWM, the Zig client catalog deletions finish |
| 72 | Charm TUI: window-tty VT (SGR/CUP/EL/ED/alt screen), a Bubble Tea hello, the `load_max`/`map_max` loader bound split |
| 73 | Terminal depth: fourteen cards — palette theming, resize, the acceptance chain (index #1624) |
| 74 | TUI apps: `GOFILES.ELF` becomes a Bubble Tea file manager (index #1639) |
| 75 | Docs & site truth-up: the watermark guard and this page's own honesty rules (index #1669) |
| 76 | Boot past the wall (index #1673) |
| 77 | TUIOS exploration (index #1678) |
| 78 | Final Zig user-source inventory: ten superseded apps retired, 62 survivors classified (index #1685) |
| 79 | Go seat depth + appkit: the persistent live seat, rail chrome, session honesty, appkit dialogs, notify (index #1703) |
| 80 | Terminal you can live in: DSR/CPR, the terminal outlives its shell, line-editor depth, prompt escapes (index #1716) |
| 81 | Files as a platform: one mime table + handler registry, snapshots, trash + recent, file watching (index #1781) |
| 82 | The app platform: a versioned `apps.txt` schema, the chord registry, the notifications center, per-app logs + crash receipts (index #1782) |
| 83 | Time, keys, and idle: wall time at EL0, SNTP clock set (slot 78), timezone, keyboard layouts, dead keys, idle dim (index #1783) |
| 84 | Remote framebuffer: opt-in in-seat RFB 3.8, every drop reason named, a VNC-auth bridge so macOS Screen Sharing connects (index #1807) |
| 85 | Terminal graphics: streaming sixel decode + `IMGCAT.ELF` (index #1808) |
| 86 | Window chrome & UI primitives: contract v1, twenty chrome glyphs, the AA shape renderer (index #1816) |
| 87 | First impressions + remote terminal: launcher, staging, the remote console (index #1856) |
| 88 | JavaScript via embedded QuickJS (`live-quickjs`; index #1915) |
| 89 | PDF support, scoped subset: the bounded v1 Go PDF engine; ADR 0040 (index #1916) |
| 90 | SVG rendering: the bounded vector subset; ADR 0041 (index #1917) |
| 91 | Local desktop readiness: virtio-console TX, an owner human session 7/7 (index #1914) |
| 92 | Init and service supervision: `INIT.ELF` declarative manifests, restart policies, a mid-boot-kill acceptance; ADR 0042 (index #1985) |
| 93 | Dillo-tier browser subset: the exact-RGB8/SHA-256 live-web comparator, K = 3 (index #1992) |
| 94 | Debugger and observability: tracer, 100 Hz sampler, heap analyzer, crash receipts; ADR 0043 (index #2000) |
| 95 | Gostalgia as a guest: the static `GOSTALGIA.ELF` ships and launches (index #2008) |
| 96 | Zig 0.17.0 toolchain port: the flag-day port of build/kernel/user/zc landed; the owner acceptance run is the remaining step (index #2060) |
| 97 | Security audit of the trust boundaries: ~40 deduplicated findings, every Sev-A/B owned and fixed (index #2069) |
| 98 | GOSH polish + the agent control channel: a pure-Go `shlib` engine behind GOSH/GOTERM, and `AGENTD.ELF` serving six verbs behind an HMAC challenge; ADR 0044 (indexes #2126, #2145) |
| 99 | Go desktop/tooling depth: sound, networking, and web typography end to end (index #2178) |
| 100 | A disk of our own: VLFS, a journaled guest filesystem on a dedicated virtio-blk image — ordered journal commits, a real fsync barrier, `mkfs.vlfs --check` host fsck, the opt-in `/disk` data root, and the standing crash gate `live-vlfs-crash` (K=5 kill-mid-write cycles); ADR 0050 (index #2302) |
| 101 | Software arrives signed: `FLINT.ELF` speaks FLINT-SYNC/1 (`clone`/`pull`/`push`/`ls-remote`) against a pinned publisher keyring, and `STORE.ELF` `ls`/`install`/`remove`/`update`/`rollback` re-authenticates the signed release manifest atom-for-atom with a retained `.prev` rollback target (index #2303) |
| 102 | Custom-virtio GPU 3D: an opt-in Metal render device beside the native 2D scanout (index #2160) |
| 103 | FLINT M0, agent-native SCM: atoms, ops, signed changes, a semantic three-way merge; ADR 0049 |
| 104 | UI depth: primitives v2, widget faces, seat chrome, composite goldens (index #2267) |
| 105 | FLINT host client: the cross-platform Zig client, shipped in [flint-client](https://github.com/drawmeanelephant/flint-client) |
| 106 | FLINT host server: `flintd`, the Zig FLINT-SYNC/1 server, shipped in [flint-server](https://github.com/drawmeanelephant/flint-server) |
| 107 | The guest builds the guest: `GOBUILD.ELF` drives the in-guest `cmd/compile`/`cmd/link`, GOEDIT navigates diagnostics, `flint status`/`diff`/`commit`/`push` versions the session, and the `GODIFF.ELF` capstone was authored, compiled, run, and pushed entirely in-guest; standing gate `live-dev-loop` (index #2304) |
| 108 | Through the glass: ADR 0051's consented host lanes — bidirectional clipboard over signed VHI1 share files, host→guest file drop into `/host/INBOX`, seat toasts crossing out to macOS banners; standing gate `live-hostint` (index #2305) |
| 109 | Agents as first-class citizens: ADR 0052 agent identity, agentd + audit, the agent-view seat, third-party agent apps, the GOTAB seat — landed; the reference-host K=5 + owner sign-off caveat stands (index #2382) |
| 110 | The store as an ecosystem: the release manifest *is* the catalog entry, publisher fingerprints derive from signing keys, GOSTORE browses/installs/rolls back, and a third-party publisher drill proves `key_unknown`/`key_revoked` refuse at materialization; ADR 0055 (index #2383) |
| 111 | The Metal GPU as a bounded compute device: slot-90 `sys_gpucomp`, GEMM/SOFTMAX/DEQUANT pipelines, and GOINFER answering in-guest on the real Metal path (a 135M-parameter model, Apache-2.0); ADR 0053 (index #2384) |
| 112 | Self-host the userspace: `GOBUILD fleet` builds the pinned fleet rows in-guest, `GOBUILD test` runs the package suite (796 tests), and `GORELEASE assemble` writes a byte-identical boot image in-guest that the host boots; `live-release` (index #2385) |
| 113 | Trust depth: verified + measured boot, `grant`/`word`/`deny` with audit verdicts, signed `ReleaseCaps` + a GOSET consent pane, a GOTOP Trust tab; ADR 0054 (index #2386) |
| 114 | The host app becomes a Mac app: `HostCommand` bus + menus, 16:9 resizable/fullscreen with key capture, HostInt lanes on by default, an inspector drawer, bounded MP4 recording; `live-host-ui` (index #2447) |
| 115 | The machine keeps itself: a vsock probe, the `virelai-ctl/1` HMAC channel (ADR 0056), `.virelaivm` profile bundles, guest-driven suspend/resume, `GOSNAP.ELF` share snapshots, and guest-staged signed OS self-update with `.prev` rollback; `live-persistence` K=3 (index #2448) |
| 116 | Trust defaults enforce: the compiled baseline grant table, the enforce flip with named `EACCES` refusals, install-time consent, and `net` `host:port` allowlists; `live-sandbox-negatives` + `live-trust-journey` (index #2449) |
| 117 | IPv6 and a real LAN: v6 demux/SLAAC/NDP/ICMPv6, UDP/TCP v6 + `ping6`, `--net-bridged`/`--net-vmnet`, grant policy over v6 prefixes, and a bridged guest reading a real LAN httpd; ADR 0057 (index #2450) |
| 118 | Bounded audio capture: the virtio-snd RX queue and cap table, slots 91/92 `sys_audio_rec*`, `GOREC.ELF` recording WAV, a mic meter — and a mic-denied host answers with the pinned bounded refusal, not a file (index #2451) |
| 119 | Performance is a contract: the bench corpus + budgets, `live-bench` with its forced-breach negative, and the named bounds it characterized (see [[benchmarks]]); landed, owner sign-off owed (index #2452) |
| 120 | The session keeps itself: persistence wiring, `SESSION.TABS` live re-exec, Machine-menu lifecycle verbs, windowed GOSNAP; `live-session-ux` K=3 (index #2548) |
| 121 | Keyboard-first daily driver: the `Ctrl+Shift+P` palette, tab chords, a `?` hints overlay, the focus badge, cross-app `Ctrl+Z` — acceptance is a pointer-free `go-dogfood` boot, K=3 (index #2549) |
| 122 | First-hour onboarding: incremental session builds + toolchain doctor, the GOWELCOME first-boot tour, launcher ghost-app purge, host toolbar + `⌘/` cheat-sheet, a clickable GOSET (index #2550) |
| 123 | Visible system feedback: kernel refusals surface as actionable toasts, shared empty states, `appkit.Progress` + cancelable notify rows, `appkit.ErrorBanner` adoption (index #2551) |
| 124 | Cross-app data flow: guest drag-and-drop over WM_RPC, a shared `appkit.FilePicker`, the typed clipboard with host negotiation, Open With, primary selection (index #2552) |
| 125 | Session fidelity: per-app save/restore over WM_RPC + `.tabs` v2 for GOEDIT/GOFILES/WEB/GOTERM, crash → auto-snapshot + recovery toast, and a snapshot→hard-kill→restore acceptance, K=5 (index #2553) |
| 126 | Web browser parity: history dropdown, bookmarks, find-in-page, per-tab zoom, the download flow; `live-web` K=3 (index #2554) |
| 127 | Through the glass 2.0: drop-to-open, notify click-through, the OUTBOX export lane, an AGENTD companion; ADR 0051 v2 (index #2555) |
| 128 | Workstation profiles: `⌘,` machine settings, a profile manager (new/clone/reset/switch), `.virelaivm` Finder documents; `live-workstation-profiles` 12/12, K=3 (index #2556) |
| 129 | Headroom: 512 MiB compiled default + the >256 MiB boot fix, task pool 16→64 with a spawn-storm leg, and the measured capacity table (index #2557) |
| 130 | It runs Doom — legally: ADR 0058 keeps GPL out of this repository; the engine lives in a sibling repo behind a `DG_*` shim and arrives as a signed STORE payload, and `live-doom` walks store-install → consent → `-playdemo` E1M1 → clean exit, K=3 (index #2617) |
| 131 | Warm checkpoints: ADR 0059's boot-once-restore-per-leg semantics, the `vgate_checkpoint`/`--from-checkpoint` primitives, the `live-quickjs` pilot, and the fleet census (index #2637) |
| 132 | Wave contracts: the ADR 0007 slot reservation table + reserved seat chords, manifest/grant/mime/clipboard rows for every new app, and HF serving extracted into `HostFileServer.swift` (index #2734) |
| 133 | Kernel depth: named OOM, scheduler aging, the 512 MiB capacity re-audit + spawn-storm retune (index #2735) |
| 134 | Storage depth: HF STAT mtime, an enumerable mount table with named `not_mounted`, VLFS mount-time read-only check (index #2736) |
| 135 | Net depth: the TLS 1.3 server half (GOHTTPD serves HTTPS), HTTP/1.1 keep-alive + chunked + gzip, listen depth with named saturation (index #2737) |
| 136 | Media decode: a shared flate inflater, bounded baseline JPEG, bounded first-frame GIF — five formats in one viewer (index #2738) |
| 137 | Seat depth: split panes as a tree, appkit controls v2 (menu bar/tree/table), spaces — named tab groups (index #2739) |
| 138 | Shell & dev-loop depth: shlib heredocs, GOEDIT bracket matching/diagnostics/format-on-save, `flint blame`/`graph`/`tags` + GODIFF side-by-side (index #2740) |
| 139 | Host app, agent surface, gate fleet, docs truth: multi-VM windows, AGENTD `ui.input`, the `live-wnd*` fleet diet, TEAMS.md (index #2741) |
| 140 | GOASSIST: the `user/go/infer` engine behind a chat app — real-model journey, snapshot, restore; `go-assist` K=3 (index #2742) |
| 141 | GOPAINT: a paint app shipped through the STORE bundle path, K=3 (index #2743) |
| 142 | GOSHEET: cells/formulas/grid, CSV + session state; `go-sheet` K=3 — edit, export, reopen in GOEDIT (index #2744) |
| 143 | GOREADER: a reader app; K=3 open-chain journey (index #2745) |
| 144 | GOCLOCK: alarms persist via `save_state` + a share file and late-fire on start (index #2746) |
| 145 | Games: GOMINE + GOSOL — play both, snapshot mid-game, restore exactly, K=3 (index #2747) |
| 146 | GOEMOJI: a chord-summoned picker whose selection lands on the typed clipboard; `go-emoji` K=3 (index #2748) |
| 147 | GOIRC: an IRC client — TLS + consent journey, snapshot, restore; `go-irc` K=3 (index #2749) |
| 148 | GOVAULT: a secrets vault whose own audit file is the receipt; K=3 (index #2750) |
| 149 | Shipped-app polish: GOFILES spacebar QuickLook, GOTERM OSC-8 links + named profiles, GOEDIT themes + a minimap (index #2751) |

Every milestone through **M149** is landed or closed. `docs/status.md` is
the ledger. For a curated account of merged work from 2026-09-01 through
2026-10-02, see the [[chronicle|weekly merged-PR chronicle]].

## Current

The ledger is nearly clean: every index through M149 is closed except the
lanes below, which are landed-but-not-yet-signed-off rather than unbuilt.

- **M96, the Zig 0.17.0 toolchain port**
  ([#2060](https://github.com/drawmeanelephant/VirelaiOS/issues/2060)) —
  all five cards landed, including the `build.zig`/kernel/user/zc flag-day
  port and the `@bitCast` audit; the index closes by owner hand on the K=3
  class-A + class-B acceptance run under the pinned 0.17 SDK.
- **M109, agents as first-class citizens**
  ([#2382](https://github.com/drawmeanelephant/VirelaiOS/issues/2382)) —
  landed-with-caveat: all six cards are in and the acceptance gates went
  green on the dev host (`live-agent-loop` K=5 35/35, `go-agentd` 14/14,
  `go-top` 8/8, `go-wm-seat` 20/20); the reference-host K=5 plus owner
  sign-off are still owed.
- **M119, performance as a contract**
  ([#2452](https://github.com/drawmeanelephant/VirelaiOS/issues/2452)) —
  landed: `live-bench` 18/18 on the dev host plus the headroom legs all
  PASS ([[benchmarks]]). Per the re-scope, the reference-host full-fleet
  pass + K=3 soak is an owner-run background check, not a merge gate; the
  index closes on owner sign-off.
- **M103, FLINT SCM M0** — all four cards landed (atoms, ops, signed
  changes, the semantic merge; `go-flint` green); the ledger marks it
  *landed* rather than closed.
- **M131, warm checkpoints** ([#2637](https://github.com/drawmeanelephant/VirelaiOS/issues/2637))
  — closed on the ledger: all four cards landed (ADR 0059, the
  checkpoint/resume primitives, the `live-quickjs` pilot, the fleet
  census). The ledger still carries a stale second M131 row reading
  "Filed" from before the land; the closed row is the truth.

Honest-bound edges that remain regardless of milestone:

- **The balloon device** — not attached. Demand paging does not itself
  provide memory reclaim.
- **The guest is an endpoint, not a router** — M117 added IPv6 and a real
  bridged LAN (`--net-bridged` needs the vmnet entitlement), but nothing
  forwards for other hosts, and TCP RTO stays fixed rather than adaptive.
- **Multi-display** — the guest stays single-display. Accelerated 3D exists
  only as the opt-in M102 custom-virtio Metal device; the default desktop
  is 2D.
- **GPL stays out of the repository** — even Doom rides the signed store
  channel from its own sibling repo (M130, ADR 0058).

Both former "open thread" caveats are resolved and shipped: the M8 U4
pointer-focus proof is now class-B-headless via custom-virtio pointer
injection (claim 9367), and the synthesized-keyboard `events=0` report is
fixed by the headless virtio input channel (claims 9588/0680).

<Aside kind="note">

**PLANNED.** This page is a summary, not a live card tracker. Check
[`docs/status.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/status.md)
and the linked issues for current work; the [[evidence]] page explains how
this site distinguishes landed work from observed behavior.

</Aside>

## How to read the status

- **Shipped** = landed, merged, and gated.
- **Landed / landed-with-caveat** = every card merged and the gates green on
  the dev host, with the owner sign-off or reference-host soak still owed.
- **In progress** = claimed on a branch, not yet merged.
- **Planned** = sketched, with no gate yet.

The repository distinguishes these strictly: claims are only flipped to
observed when the matching live gate passes, and the [[evidence]] page
explains the classification.

<Aside kind="warning">

**LIMITATION.** Do not read the repository's `docs/` planning prompts as
shipped features. The planning tree is an engineering warehouse; this site
is the public index of what actually landed.

</Aside>
