---
title: User programs & demos
parent: capabilities
status: published
tags: [capabilities, userspace, demos]
---

# User programs & demos

The boot image carries the loader and kernel; user images are staged from the
host share and run at EL0. This page is a seam-proof and application history,
not a claim that every row is a current build output. Rows marked retired or
deleted are historical; current boot and desktop applications are identified
separately below. The SB*/SMP*/WMRPC gate fixtures are elided, as are the
dynamic executables and shared libraries listed after the table. Go ELFs are
built by pinned host-toolchain recipes and staged by their gates.

| Image | Source | Proves |
|-------|--------|--------|
| `USER.BIN` | `user/src/main.zig` | the basic EL0 path: `sys_write`, pings, exit status |
| `COUNTER.BIN` | `user/src/counter.zig` | a never-exiting program that sends IPC and optionally waits |
| `PEER.BIN` | `user/src/peer.zig` | IPC receive: echoes `peer: got ping N` |
| `STATUS43.BIN` | `user/src/status43.zig` | `sys_wait`'s target: sleeps, then exits 43 |
| `UDP.BIN` | `user/src/udp.zig` | the UDP syscall seam: listen, loopback, peer datagram, exit 17 |
| `WIN.BIN` | `user/src/win.zig` | `sys_win_open`/`fill`/`present` — EL0 graphics |
| `WINCLOSE.BIN` | `user/src/winclose.zig` | `sys_win_close` and slot reuse |
| `WINLOOP.BIN` | `user/src/winloop.zig` | a window kept alive across the pixel proof |
| `WINMOVE.BIN` | `user/src/winmove.zig` | move/raise/get/query/set_visible — the full window seam |
| `KEYTEST.BIN` | `user/src/keytest.zig` | the interactive event loop: `sys_poll_event`/`sys_wait_event` |
| `SAVETEXT.BIN` | `user/src/savetext.zig` (deleted M78c) | retired storage demo; `GOSH.ELF` redirection now proves persistence in `live-user-fs` |
| `TYPE.BIN` | `user/src/type.zig` (deleted M78c) | retired storage demo; `GOSH.ELF` `cat` now proves reads in `live-user-fs` |
| `DIR.BIN` | `user/src/dir.zig` (deleted M78c) | retired storage demo; `GOFILES.ELF` now proves directory listing |
| `CALC.BIN` | `user/src/calc.zig` | the graphical calculator (checked arithmetic, repeat, memory) — M62h (#1406): RETIRED, `user/src/calc.zig` deleted; the calculator is the Go `GOCALC.ELF` (`user/go/calc`) |
| `NOTEPAD.BIN` | `user/src/notepad.zig` | the graphical editor, load/save `/data/notes.txt`, scrollable viewport — M66c (#1485): RETIRED, `user/src/notepad.zig` deleted; the editor is the Go `NOTE.ELF` (`user/go/note`) |
| `TOP.BIN` | `user/src/top.zig` (deleted M71g) | the graphical process monitor with click-to-kill (`sys_kill`) — since retired to Go (`GOTOP.ELF`, gate `go-top`) |
| `DESKTOP.BIN` | `user/src/desktop.zig` (deleted M78c) | retired Zig launcher; `GOTABWM.ELF` owns the seat, manifest, launcher, and hosted `sys_exec` path |
| `TCP.BIN` | `user/src/tcp_client.zig` | the TCP syscall seam: connect, send, receive echo, close, exit 18 |
| `GOFETCH.ELF` | `user/go/fetch` | M67b: an HTTPS client over in-process TLS (windowed, exit on close); issue #1683: RETIRED `FETCH.BIN` and `DOWNLOAD.BIN`, `user/src/fetch.zig` and `user/src/download.zig` deleted — one binary now owns the cleartext fetch (`http://` on the console, exit 42) and `--download` (saves the body to the host share) |
| `CHAT.BIN` | `user/src/chat.zig` (deleted M78c) | retired graphical UDP demo; the UDP seam remains live-tested without a product-app fixture |
| `FSTEST.BIN` | `user/src/fstest.zig` (deleted M34 HF6) | the mutating filesystem seam: create/write → truncate → rename → free → delete — the proof was deleted with the second volume (#740); the slots remain |
| `TIMER.BIN` | `user/src/timertest.zig` | the app-timer seam: arm → block on `TIMER` event → cancel |
| `VICTIM.BIN` | `user/src/hardening_victim.zig` | the hostile-EL0 proof's victim: owns a window and yield-loops forever |
| `HARDEN.BIN` | `user/src/harden.zig` | the hostile-EL0 proof's attacker: refused EINVAL on every cross-process window call |
| `JINGLE.BIN` | `user/src/jingle.zig` | the EL0 audio seam: learns the negotiated PCM state, plays Twinkle Twinkle Little Star |
| `CHIME.BIN` | `user/src/chime.zig` | event-triggered sound: arms an app timer, blips 880 Hz on every `TIMER` event |
| `GLOBALS.BIN` | `user/src/globals.zig` | M16 C1: the first segmented DSK3 image — writable globals past the old 16 KiB bound |
| `GUARD.BIN` | `user/src/guard.zig` | M16 C2: steps into its guard page and is reaped 139 |
| `ASM.BIN` | `user/src/asm.zig` | M22 D2: the assembler |
| `DISAS.BIN` | `user/src/disas.zig` | M22 D4: the disassembler |
| `PS.BIN` | `user/src/ps.zig` | M22 D6: the process list |
| `RESMON.BIN` | `user/src/resmon.zig` | M22 D10: the resource monitor |
| `DEVCONS.BIN` | `user/src/devcons.zig` | M22 D14: the developer console |
| `EDIT.BIN` | `user/src/edit.zig` (deleted M60) | M23: the text editor (undo/redo, goto, tabs, syntax, console split) — since retired to Go (`GOEDIT.ELF`, gate `go-edit`) |
| `SETTINGS.BIN` | `user/src/settings_panel.zig` | the persistent settings panel — M71f (#1565): RETIRED, `user/src/settings_panel.zig` deleted; the panel is the Go `GOSET.ELF` (`user/go/settings`), writing the same schema-v2 `SETTINGS.TXT` the seat reads |
| `M21DEMO.BIN` | `user/src/m21demo.zig` | M21 W1/W2 tiling + master-detail gate payload |
| `SYSMON.BIN` | `user/src/sysmon.zig` (deleted M71g) | M27 G6: the system monitor dashboard — since retired; one successor `GOTOP.ELF` covers both rows |
| `PING.BIN` | `user/src/ping.zig` (deleted M71n) | M26 N1: the ICMP ping seam (`sys_ping_send`/`sys_ping_poll`) — since retired to Go (`GOPING.ELF`, gate `go-net-clis`) |
| `NETSTAT.BIN` | `user/src/netstat.zig` (deleted) | M26 N2: network dashboard — retired to Go (`GONETSTAT.ELF`, `user/go/netstat`, gate `live-netstat`) |
| `DNS.BIN` | `user/src/dns.zig` (deleted) | M26 N5: DNS lookup — retired to Go (`GODNS.ELF`, `user/go/dns`, gate `live-n5-dns`) |
| `TRACEROUTE.BIN` | `user/src/traceroute.zig` (deleted) | M26 N7: direct-peer ICMP diagnostic — retired to Go (`GOTRACEROUTE.ELF`, `user/go/traceroute`, gate `live-n7-traceroute`) |

| `NETPROF.BIN` | `user/src/netprof.zig` | M26 N12: network profile manager |
| `VMTEST.BIN` | `user/src/vmtest.zig` | M29: demand-fault, COW, mmap/munmap, zero-leak teardown |
| `HTTPD.BIN` | `user/src/httpd.zig` (deleted M71l) | the in-guest HTTP/1.1 web server (TCP passive open, claim 0750) — since retired to Go (`GOHTTPD.ELF`, gate `live-httpd`) |

The three diagnostic apps' Zig implementations were replaced by Go in this
change; their build recipe is `bash tools/go/build-netdiag.sh`.

**Dynamic executables, Go ELFs, and shared libraries (M30/M31):**

| Image | Source | Proves |
|-------|--------|--------|
| `LD.SO` | `user/src/ld.zig` | M30: the freestanding runtime linker (PT_DYNAMIC, GOT relocations, AuxV) |
| `LIBUI.SO` / `LIBFONT.SO` | `tools/mkdyn-elf.py` | M30: position-independent UI + font shared libraries |
| `DYNAPP.ELF` | `tools/mkdyn-elf.py` | M30 D4: the dynamic-executable proof — links both libraries, opens a window, exits 0 |
| `CALC.ELF` / `NOTEPAD.ELF` / `FILE.ELF` / `DESKTOP.ELF` | `tools/mkdyn-elf.py` (M31 migration fixtures) | M31 E1–E4: the desktop apps rebuilt as dynamic executables (`FILE.ELF` is the dynlink fixture; Zig `FILE.BIN` was deleted in M60) |
| `GOFILES.ELF` | `user/go/files` | M58a/M60: Go file manager (list/open on the host share; gate `go-fileman`). Zig `FILE.BIN` deleted. |
| `GONETSTAT.ELF` | `user/go/netstat` (`tools/go/build-netdiag.sh`) | slot-62 network dashboard; gate `live-netstat` |
| `GODNS.ELF` | `user/go/dns` (`tools/go/build-netdiag.sh`) | UDP DNS A-record lookup; gate `live-n5-dns` |
| `GOTRACEROUTE.ELF` | `user/go/traceroute` (`tools/go/build-netdiag.sh`) | bounded direct-peer ICMP echo reachability; gate `live-n7-traceroute` |
| `FLINT.ELF` | `user/go/flint` | M103/M101: the agent-native SCM — Atoms/Ops/Streams with Ed25519-signed Changes — speaking FLINT-SYNC/1 (`clone`/`pull`/`push`/`ls-remote`) behind a pinned publisher keyring; gate `go-flint` |
| `GOBUILD.ELF` | `user/go/gobuild` (`tools/go/build-gobuild.sh`) | M107a/b: the in-guest build driver — import graph, `-importcfg` generation, `GOCMDCOMPILE.ELF`/`GOCMDLINK.ELF` children, named refusals (`dep_unsupported`, `closure_too_large`); gate `live-gobuild` |
| `BTMATH.ELF` | `user/go/btmath` (`tools/go/build-btmath.sh`) | Bubble Tea v2's real `tea.Program` under `GOOS=virelai` via the M72c compiler-overlay mechanism (module-cache source, no vendor dump); gate `go-btmath` |
| `PLUGIN.SO` | loaded via `dlopen`/`dlsym` | M31 E5: runtime-loadable plugin modules |

The flat images come from `zig build` (Zig → ELF → `elf2bin.py` → a flat
image) and seed the host share at gate time; the dynamic `.ELF`/`.SO`
fixtures come from `tools/mkdyn-elf.py`, while guest Go ELFs are built by
pinned GOOS=virelai host-toolchain recipes. The boot image itself carries only
`BOOTAA64.EFI` + `KERNEL.BIN` (M34 HF6).

<Aside kind="note">

**MIX.** The early images are seam-proving demos; the milestone-eleven and
later images are real applications — a calculator, an editor, a process
monitor, a desktop launcher, a file browser, a text editor, developer tools,
and network apps — built on the zero-heap `ui.zig` widget toolkit or the guest
Go UI bindings, and launched from the desktop or shell. Since M30 some apps
also ship as dynamic `.ELF` executables linked at runtime by `LD.SO`.

</Aside>
