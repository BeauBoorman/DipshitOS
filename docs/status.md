# VirelaiOS — status

> **Host identity:** Apple silicon running macOS 27 or newer only, hosted by
> Apple's Virtualization.framework; **not Linux, not Unix, not QEMU**
> (`AGENTS.md`). The runner enforces the macOS 27+ floor at runtime.

> Living status tracker. **Claims are GitHub issues labeled `claim`** (see
> [Multiagent coordination](#multiagent-coordination)), not repo files. Keep
> this file a compact table: per-card detail lives on the issue and its
> `docs/march-m*.md` tracker, not here. Gates are the evidence — **observed**
> (saved gate output / CI) versus **inferred** (reasoning only). The
> pre-compaction text (the M17–M51 gate-by-gate narrative, 2026-09-12,
> 687 lines) is preserved in git history at `e5480c9`.

## Milestones

All milestones through M52 are complete. Closed-milestone detail is under
`docs/archive/` and in the per-arc `docs/march-m*.md` trackers; open cards, if
any, are on the GitHub tracker.

| # | Milestone | What it proved | Status |
|---|-----------|----------------|--------|
| 0 | Boot pipeline | A Zig AArch64 UEFI app on a FAT32 ESP boots under real firmware (`\BOOTED.TXT`) | ✅ |
| 1 | Kernel handoff | `KERNEL.BIN` loaded, cache-maintained, jumped to, and returned (`kernel_rc=0x0`); ADR 0002 | ✅ |
| 2 | Kernel proper | `ExitBootServices`, captured EFI map, identity TTBR0_EL1 tables, MMIO serial + polled TX console; ADR 0004 | ✅ 2026-08-08 |
| 1.5 | Interactive Kernel Monitor | Live interactive serial console (TX+RX); tag `m1.5-interactive-monitor` | ✅ 2026-08-09 |
| 3 | Allocator, interrupts, tasks | Physical allocator, GIC+timer, tasks, EL0/SVC, syscall ABI 0–4, uaccess, per-task TTBR0, ESP exec, sleep | ✅ 2026-08-10 |
| 4 | Real randomness | Virtio entropy + ChaCha20 CSPRNG, ASLR, DATA partition, process abstraction | ✅ 2026-08-11 |
| 5 | Networking | Virtio-net TX/RX, ARP, IPv4, UDP, NAT, DHCP, TCP + retransmission | ✅ 2026-08-12 |
| 6 | Graphics | Virtio-gpu (1280×720), text, Road Pops, Driving Award WM, draw syscalls 12–15 | ✅ 2026-08-13 |
| 7 | Input | Apple XHCI + HID keyboard/pointer, event FIFO → line editor | ✅ 2026-08-13 |
| 8 | Usability (ADR 0008) | Grouped help, line editor/history, error contract, HIG, motd/about/sysinfo/settings | ✅ 2026-08-15 |
| 9 | App events (ADR 0009) | Per-process event queues, `sys_poll_event`/`sys_wait_event`, KEYTEST.BIN | ✅ 2026-08-15 |
| 10 | Userland FS (ADR 0010) | Per-process file table, path canon, slots 23–27; live clients: GOSH/GOFILES | ✅ 2026-08-15 |
| 11 | Desktop (ADR 0011) | Toolkit ui.zig/font8x8; shipping seat and clients: GOTABWM + Go ELFs | ✅ 2026-08-16 |
| 12 | Net apps (ADR 0012) | TCP slots 30–33; DNS/fetch/product clients are Go ELFs | ✅ 2026-08-16 |
| 13 | Files & apps | Mutating FS (delete/rename/truncate), APPS.TXT manifest, FILE.BIN | ✅ 2026-08-16 |
| 14 | Shared services | Clipboard, app timers, NOTEPAD composition, hardening | ✅ 2026-08-18 |
| 15 | Audio | Virtio-snd (DID 0x1059), PCM playback, `sys_audio` 42–45, JINGLE/CHIME.BIN | ✅ 2026-08-18 |
| 16 | Kernel grows up | DSK3 segmented image, guard pages, grown pools | ✅ 2026-08-19 |
| 17 | Desktop completeness | C1–C10 + Arc1–5: widget depth, window management, app upgrades, polish | ✅ 2026-08-21 |
| 18 | Terminal & shell depth | T1–T16: scrollback, selection, search, persistent history, colors, scripting | ✅ 2026-08-24 |
| 19 | Shell programming | P1–P16: pipes (56/57), redirection, env, functions, substitution, arithmetic, conditionals | ✅ 2026-08-24 |
| 20 | Text & Unicode | U1–U5: font sizes, Unicode glyphs, search, chrome, tabs | ✅ 2026-08-23 |
| 21 | Window depth | W1–W16: tiling, minimize, alt-tab, notification center, maximize, focus rings | ✅ 2026-08-26 |
| 22 | Developer tools | D1–D16: ELF loader, assembler, symbols, disassembler, strace, ps, dmesg | ✅ 2026-08-25 |
| 23 | The text editor | E1–E25: EDIT.BIN, undo/redo, goto, tabs, syntax, console split | ✅ 2026-08-26 |
| 24 | CALC grows up | K1–K16: programmer mode, memory, units, constants, history | ✅ 2026-08-23 |
| 25 | File manager depth | F1–F18: du, sort, overwrite/conflict, path copy | ✅ 2026-08-26 |
| 26 | Network experience | N1–N16: ping, netstat, traceroute, HTTP fetch display, download mgr | ✅ 2026-08-26 |
| 27 | Desktop polish | G1–G30: splash, wizard, previews, sounds, sysmon, tooltips, audits | ✅ 2026-08-27 |
| 28 | SMP | PSCI CPU_ON bringup, per-core schedulers, spinlocks, GICv3 SGI IPIs | ✅ 2026-08-27 |
| 29 | VM depth | Demand paging, COW page sharing, anonymous mmap, zero-leak teardown | ✅ 2026-08-27 |
| 30 | Dynamic linking | Freestanding `LD.SO`, `LIBUI.SO`/`LIBFONT.SO`, W^X multi-aperture | ✅ 2026-08-27 |
| 31 | Dyn-linking ecosystem | CALC/NOTEPAD/FILE/DESKTOP → `.ELF`, runtime `dlopen`/`dlsym` | ✅ 2026-08-27 |
| 32 | WM server migration | Seam A: desktop policy to a userland WM server (slot 65), kernel slimmed WMS1–WMS9 | ✅ 2026-08-30 |
| 33 | Seam B | Full pixel ownership: shared-anon mmap, apps own buffers, WM composes one present | ✅ 2026-08-31 |
| 34 | FAT-free storage | Host file channel HF1–HF7 (macOS share over custom-virtio); FAT removed; CLONE dedup | ✅ 2026-09-02 |
| 35 | WASM core interpreter | `WASM.BIN` interpreter, frozen `env.*` surface, `wc` capstone | ✅ 2026-09-02 |
| 37 | Desktop quality pass | God Menu overlay, tab strip render + mouse, design tokens, snap guides | ✅ 2026-09-03 |
| 38 | Vector typography | TrueType Inter/Fira Code, anti-aliased BGRA blending, proportional metrics | ✅ 2026-09-03 |
| 39 | Tabbed desktop & modular UI | Modular `ui.zig`, rounded rects, `TABWM.BIN`, tab lifecycle, viewports | ✅ 2026-09-04 |
| 41 | Test separation | Parallel `zig build test`, shared mocks, de-monolithized source | ✅ 2026-09-04 |
| 42 | The Sexiburger desktop | Mascot raster, WM→app resize seam, `lib/tabapp.zig`, full-viewport, UX hardening round 2 | ✅ 2026-09-05 |
| 43 | Device depth (USB) | XHCI bulk engine, USB mass storage (BOT+SCSI), `.usb` block seam, lifecycle | ✅ 2026-09-10 |
| 44 | Terminal (vt) seam | `/dev/tty` device file, ADR 0007 slot 67 `sys_tty_attach`, `TTYECHO.BIN`; ADR 0020 | ✅ 2026-09-11 |
| 45 | Userland shell & front-ends | `tty.zig` editor, `SH.BIN`, `TERM.BIN`, net front-end, default-shell flip; ADR 0021 | ✅ 2026-09-11 |
| 46 | Remote access Stage 0/1 | `--console-tcp`, guest net auth, RC0–RC4; ADR 0022 | ✅ 2026-09-11 |
| 47 | Crypto primitives | SHA-256/512, HMAC, ChaCha20, Ed25519; ADR 0023 | ✅ 2026-09-11 |
| 48 | Browser-style tab depth | Rail-native tabs: reopen/duplicate, reorder, pin/group, start surface, per-tab history, preview (umbrella #1120) | ✅ 2026-09-10 |
| 49 | A shell I'd use daily | `monitor` detach, startup contract, `toolbox.zig` multicall, editing ergonomics | ✅ 2026-09-11 |
| 50 | Trust & isolation | uid/caps, permissions, secrets, authenticated remote, privilege gating; ADR 0024 | ✅ 2026-09-11 |
| 51 | SSH | Userland SSH-2 client `SSH.BIN`; real-OpenSSH interop; ADR 0025 | ✅ 2026-09-12 |
| 52 | Client-death hardening | Exit/revoke teardown pinned end-to-end: a client dying with focus, a drag, or a bound surface leaves no zombie window, stale mapping, stuck capture, or dead-seat routing (umbrella #1237) | ✅ 2026-09-14 |
| 53 | TLS 1.3 client + trust store | In-tree TLS 1.3 end to end: HKDF/SHA-384/AES-GCM, X.509 + chain validation, RSA/ECDSA verification, the handshake state machine; real interop against 4 peer implementations and 8 public endpoints, 5 negatives fail closed; ADR 0029. #1336: `task_stack_size` 32 → 192 KiB so a live handshake completes (`FETCHS.BIN` → `GOFETCH.ELF`/`WEB.ELF`, gates `go-fetch-https`, `live-web` boot 12; `live-tls13` retired). #1337: git-over-https — `GOTGIT.ELF` clones in-process over `tls.Dial` (gate `go-git`) | ✅ 2026-09-14; stack 2026-09-16; git-over-https 2026-09-16 |
| 54 | Go carries its first app | A Go EL0 program owns a raw ADR 0007 window (`GOWIN.ELF`, gate `go-win`), an independent Go `.tabs` v2 codec round-trips the TABWM session format (`tools/go/tabcodec`), and `WEB.ELF` renders in-guest over `user/go/webrender`; kernel untouched (umbrella #1244) | ✅ 2026-09-15 |
| 56 | Finish the Go SDK (`vi` + `tabapp`) | The Go EL0 SDK is complete enough to be a WM: `vi` gains IPC 5/6 + `procs` discovery, the tab-client WM_RPC wire, and addr-hinted mmap; `user/go/widgets` adds text/button/list; `user/go/tabapp` + a demo app run one Go tab full-viewport in Zig TABWM (gate `go-tabapp`) | ✅ 2026-09-15 (gate `go-tabapp` green on VZ) |
| 59 | Default flip (#1298) | The **boot default is the Go seat**: `wm` is a schema-v2 settings key whose compiled default is `gotabwm`, so a boot with no persisted value autostarts `GOTABWM.ELF` and hosts `GOCALC.ELF` plus the Go editor `NOTE.ELF` over WM_RPC (then still Zig NOTEPAD; the Zig binary is gone since M66c/#1485); `settings set wm tabwm` keeps the Zig seat as the reachable fallback and `none` is the explicit shim-only VM (gate `go-wm-default`, 2/2 runs: the untouched default boot, then the persisted fallback) | ✅ 2026-09-15 (gate `go-wm-default` green on VZ) |
| 60 | Starve Zig EL0 (#1297) | No new `user/src/*.zig` apps (ADR 0030). Leftovers deleted: `EDIT.BIN` → `GOEDIT.ELF` (gate `go-edit`); `FILE.BIN` → `GOFILES.ELF` (gate `go-files`, #1374); `CALC.BIN` → `GOCALC.ELF` (gate `go-calc`, #1378, deleted M62h / #1406); `NOTEPAD.BIN` (M66c/#1485, PR #1495); `SH.BIN` → `GOSH.ELF` (M68b #1450: serial + trust + scripting + net/handshake, then the delete); `FETCHS.BIN` → `GOFETCH.ELF`/`WEB.ELF` (M71k/#1570, gates `go-fetch-https`, `live-web` boot 12; `lib/tls` is host-side interop only); `SETTINGS.BIN` → `GOSET.ELF` (M71f/#1565, gate `go-wm-default` boot 01); `TOP.BIN` + `SYSMON.BIN` → `GOTOP.ELF` (M71g/#1566, gate `go-top`); `VIEW.BIN` → `GOVIEW.ELF` (M71h/#1567, gate `live-image-viewer` + `go-wm-seat` run 04); `DOC.BIN` → `WEB.ELF` (M71i/#1568, gates `live-web` + `live-web-ttf`; `lib/html` and its 21 host tests went with it). `PING.BIN` → `GOPING.ELF` (M71n/#1573, gates `live-n1-ping`, `live-net-offline`, `go-net-clis`). `TABWM.BIN` is **retained by decision** as the Zig fallback (M68c #1451, ADR 0034) — not a leftover: `wm=tabwm` is a schema-v2 settings value, and gate `go-wm-default` 4/4 boots it (run 02). SSH stays `SSH.BIN`. | ✅ 2026-09-21 (EDIT/FILE/CALC/NOTEPAD/SH/FETCHS deleted; TABWM retained — ADR 0034) |
| 61 | Guest self-test (#1380) | `GOSELF.ELF` runs in-OS cases and writes `/host/SELFTEST/…` (report + intake copies + file-ABI receipts + window receipt); host only boots it and byte-compares via `share-equals`/`share-contains`; ADR 0031/0032 | ✅ 2026-09-17 |
| 63 | GOTABWM HID (#1418) | Boot-default seat drains kind 19/21; pin/Alt+Tab; rail click; type into GOEDIT (share `seed-line\nXYZ`); HID drag-reorder is `go-wm-hid` run 02 (not `go-wm-tabs` M62d choreography). Dual path ADR 0009. Runner `ctrl-tab` is hidChord (#1424). | ✅ 2026-09-18 (`go-wm-hid` 2/2, `go-wm-seat` 2/2, `go-wm-tabs` 3/3, `go-wm-default` 2/2) |
| 65 | Go threads (ADR 0027) | M65a–d landed (#1472/#1473/#1474/#1475), ADR 0007 slots 73/74 frozen, max_tasks 16 (3 + 3×4 + 1 spare) | ✅ 2026-09-18 (`go-wm-tabs` 3/3, `go-wm-seat` 2/2, `live-scale` 1/1) |
| 66 | Go owns files (storage depth) | M66a (#1443): `/host` as a surface Go can trust — honest HF error rows (`hf_open_errno`/`hf_handle_errno`: not-found/is-dir/exists/handle-full), fsync at EL0 (slot 77, ADR 0007 amendment), `vi.FileWriteAll` confirmed-count chunking, GOSELF append/bigwrite/clamp/fsync/errors receipts. M66b (#1444): crash-safe settings round-trip — `SETTINGS.TXT` saves via temp+fsync+rename (never in-place truncation; the no-overwrite HF rename makes the publish delete-then-rename), corrupt file refused whole (no valid `#v` header → defaults), `vi.FileRename`/`WriteFileSafe`, GOTABWM session/layout onto the safe path + seat-side fail-closed decode; `go-wm-default` corrupt-settings run heals byte-exact. M66c (#1445): the fleet's default editor client is the Go `NOTE.ELF` — 22 lifecycle/WM-host specs retargeted onto it, `image/apps.txt`'s dock entry, `gotabwm`'s title→binary map, and the monitor's `help editor` line (which named `NOTEPAD.BIN` and listed `EDIT.BIN`-era chords no shipped editor implements; now pinned by `live-help`). M66c follow-on (#1485): `NOTEPAD.BIN` **deleted** — `user/src/notepad.zig` and its build step gone, and the 14 specs that still exec'd it retargeted onto `NOTE.ELF` (9 mechanical: staging block + `note:` prefix + the two app-painted colour expectations in `live-wm4-paint`/`live-wm-*-chrome`) or retired with a coverage note (2 token boots; the theme table stays pinned by SYSMON/DEVCONS). The three contracts only the Zig app had moved to `GOEDIT.ELF` (find/goto, WIN_UNSAVED save-and-exit) and a new `GOCOMP.ELF` (clipboard+timer composition). Review fixes (PR #1495): GOEDIT publishes through M66b's `vi.WriteFileSafe` (temp+fsync+rename; a failed publish exits 1, not 0); the tab specs' coords were re-pinned off the retired app's rect onto the host's own (TOP declares 40,40) — `live-tabstrip` `STRIP_OK` (dividers=11, underline=118, close_red=19) and `live-tabclick` 3/3, superseding the "tree-side red" read, which was that coordinate bug. | ✅ 2026-09-19 (M66a ✅, M66b ✅, M66c retarget ✅, deletion ✅, review fixes ✅) |
| 67 | Go owns net | M67a (#1446): `vi` Dial/Send/Recv + DNS. M67b (#1447): GOFETCH/GOTGIT/WEB HTTPS in-process via `tls.Dial` over `vi.Dial` (shelf #1497); `FETCHS.BIN` → `GOFETCH.ELF`/`WEB.ELF` (gates `go-fetch-https`, `live-web` boot 12). M67c (#1448): class-B `go-fetch-https` pins the happy path plus name/expired/chain fail-closed; M71k/#1570 deleted `FETCHS.BIN` (`live-tls13` retired). | ✅ 2026-09-21 (M67a–c ✅; deletion M71k/#1570) |
| 69 | Daily driver floor | Go-seat dogfood + screenshot→site honesty + chrome cohesion + intentional typefaces + edit→build→run loop (not full self-host) + GOSH daily-bar gaps; index #1527 closed. M69g (#1558): kernel chrome skip for a fully occluded window so GOTABWM's 8,8 client-death probe no longer paints over GOSH's prompt; `go-dogfood` third boot PIXEL-asserts terminal-green on the tab's first line. | ✅ 2026-09-20 |
| 70 | Moonshots (#1437) | M70d #1456: fidelity corpus landed PR #1513 (nine pages host-goldened in `user/go/webrender/golden_test.go`; its in-VM rung moved to `live-web` boot 14 when M71i #1568 retired `DOC.BIN`); JS-in-WASM **measured negative** (Elk 22763 B inspect-clean, `exec` traps at `max_frames=32`; MIT engines miss 64 KiB / need wasm EH) — ADR 0028 D2 amended. M70g G2 (#1459, PR #1488): `--console-tcp` hardened — `busy` refusal, pre-auth deadline, line bound, stall drop, mid-line `^C` cancel, `--console-tcp-secret-file`; ADR 0022 D2 amended; `live-console-tcp`/`live-remote-console` run 03. M70g G3 (#1459): restore beyond same-process measured — cross-process restore **works** (`--vz-restore-save`/`--vz-restore-load`; VZ enforces the saved `machineIdentifier`), virtio-gpu + USB HID PASS, USB MSD 8/9 (one unreproduced refusal), custom-virtio **refused**; rows in `hardware-contract.md`, `live-vz-restore` runs save/load/gpu/usb/msd/cvc. G1 (in-guest sshd) unclaimed, blocked on M68 #1436. M70c (#1455): **complete** — all three shards landed: S1 the guest's own `cmd/compile` compiles the pinned hello (PR #1551), S2 the in-guest build loop (PR #1552, class-B `live-selfhost-go` 2/2), S3 the Zig dialect's `break`/`continue` in all three loop forms with the body's open defers unwound on the jump (PR #1511, `live-zc` run 02 + the `s3` corpus dual-run); what stays host-provided — the toolchain payload, and `GOVIRELAI_STD` still opt-in — is D4's boundary, recorded in ADR 0035 amendment 9. M70c-K (#1504): the exec bound moved — a 9.5 MiB `GOOS=virelai` image (8.4 MiB of it initialized data) now streams into its mapped pages and prints its banner read back from 1/4/8 MiB into the payload (`go-hello` run 02, 3/3), while staged shapes keep the 2 MiB buffer and oversized/truncated files still refuse by name. M70c (#1455, ADR 0035 amendment 2): with #1504 landed the exec blocker is retired and the remaining one is named with evidence — the fork has no `syscall`/`os` for `GOOS=virelai` at all (`GOOS=virelai go build fmt` fails in `src/syscall`/`internal/poll`), filed as **#1525** (M70c-S1P). **#1525 landed the port**: `GOOS=virelai go build fmt` (and `os`) now compiles — `tools/go/overlay/{syscall,internal/syscall/unix,internal/poll,time,os}` over the ADR 0007 slots, POSIX flag/errno/struct surface, honest ENOSYS for spawn/signal/net — the runtime's `os_sigpipe` linkname was added (the port's first LINK-time gap), and the std fixture `tools/go/gosyscall.go` builds and loads on VZ, but its in-guest run died in `mallocinit` (filed as **#1540**, M70c-S1L). **#1540 landed the run**: the break base now starts past the argv+envp block the kernel packs into the data segment's tail page (`initBlocFloor`), which is what the kernel's `mmap_collides` span was refusing (ADR 0035 amendment 4 corrects amendment 3: the segment shift was a coincidence — the real boundary is the data segment's page slack vs the 2304-byte block, i.e. `r > 1792`), and `go-hello` **run 05** is the first std-importing program to execute: `os.Mkdir`/`WriteFile`/`ReadDir`/`Stat`/`Remove` plus a 9.5 MiB `os.File` read whose 32-bit FNV the host recomputes off the share. The run also caught two port bugs no compile-time check could (the POSIX→kernel open-flag word, and `O_TRUNC` routed through the port's by-path `Truncate` = ENOSYS, i.e. every `os.WriteFile`). Meanwhile the transfer half is measured, not guessed: `go-hello` run 04 has the guest read a 9.5 MiB image out of the share in 4,641 calls at the 2048-byte EL0 read cap (~30 MB/s, hash re-checked on macOS). **#1543 landed the in-guest build**: the guest's own `cmd/compile` and `cmd/link` compile the pinned hello to a `virelai` object, link it into an ELF that passes every loader rule the kernel enforces, and run it to its pinned lines (`go-hello` runs 06-08, 8/8 with runs 01-05 re-run under the changed port) — the wall was not the acceptance bound but the port's missing file position (`cmd/internal/bio` seeks on package archives and on the object it writes; ADR 0035 amendment 7), and the in-guest footprint is sampled at ~33 MiB during the compile and ~131 MiB during the link of a 65,215-frame guest. **#1544 landed the build loop**: the guest's own `cmd/compile` and `cmd/link` build the pinned fixture inside ONE boot, sequenced by the guest's own spawn-and-wait rather than by the monitor (compile 2.0 s, link 14.0 s), and the gate's second boot runs the product it built (`live-selfhost-go`, 2/2) — the #1544 spike needed no new spawn slot (ADR 0035 amendment 6), and the loop keeps two children plus a monitor `exec` because that shape is proven green, not because three children are known to fail — the third-child death did not reproduce in the shape that produced it, so the wall is uncharacterised and no open card owns it (ADR 0035 amendment 8; #1449 closed). | ✅ 2026-09-20 (index #1437 closed) |
| 71 | Seat honesty | Default Go seat stops lying: hosted GOSH paints, scanout fill, rail chrome, M48 tab depth on GOTABWM, catalog deletions; index #1559 (closed); cards #1560–#1573 all landed. | ✅ 2026-09-21 (index #1559 closed) |
| 72 | Charm TUI | Window tty Charm can speak (SGR/CUP/EL/ED/alt screen), `load_max` not charging BSS, a tiny Bubble Tea hello whose proof is a 2560×1440 scanout, host VHS of that window; index #1578; cards #1579–#1582. Not a vendor dump. M72a (#1579): the loader's single bound was charged on `Σ memsz`, which is why a Go image carrying 32 MiB of `.noptrbss` (the FIPS scratch buffer every Charm-sized binary drags in) was refused as `segment_too_large` while costing no file bytes — split into `load_max` (32 MiB of INITIALIZED bytes, `Σ filesz`) and a new `map_max` (64 MiB of MAPPED bytes, `Σ memsz`, which this loader eagerly allocates and zeroes, so it is a RAM budget); the new refusal is named end to end (`map_too_large`, and never the "staging buffer" sentence the fall-through told about a gap-layout static ELF that would have streamed). `go-hello` runs 11-12 are the class-B: a 9,582,729 B Go file whose segments map 51,559,756 B EXECS and reads both ends of its 42,108,744 B `.noptrbss` tail back (`datapages=12337` held to `ceil(RW p_memsz/4096) + 1` on the host), and the same bytes with `p_memsz` at 1 GiB are refused by the new name with `staging buffer` absent. M72b (#1580): the bound window grid has 16-colour SGR/CUP/EL/ED, an alternate screen, and DECTCEM; `live-term` captures the real scanout. M72c (#1581): a tiny Bubble Tea v2 model writes into that bound tty; two Virelai-only platform stubs are compiler overlays over module-cache source, never an in-tree vendor dump. M72d (#1582): `tools/charmhello-tape.sh` records the real scanout as an artifact PNG sequence (optional host GIF), never guest video or a host ANSI render. | ✅ 2026-09-21 (all four cards landed; index #1578 closed) |
| 78 | Final Zig user-source inventory (#1685) | M78a–d retire 10 superseded/orphan Zig apps; 62 top-level survivors classified by gate/ADR; six live gates retargeted and green | ✅ 2026-09-24 |
| 87 | First impressions + remote terminal (#1856) | Launcher and staging landed (PR #1861); remote class A 5/5, class B 4/4+3/3+2/2, physical-machine class C verified. The human desktop journey (#1857, superseded by M91) is discharged by the M91 owner session: "All seven pass; no findings." | ✅ 2026-10-05 |
| 89 | PDF support, scoped subset (#1916) | Bounded v1 Go PDF subset (ADR 0040): M89a–e landed (#1920/#1940/#1950/#1959/#1971; PRs #1954/#1960/#1967/#1975); CoreGraphics replaced Poppler as the outside reference — no GPL-family code ships (LGPL CairoSVG used externally for svg-raster testing only). Final PDF pair ran on a tree identical to the merge. | ✅ 2026-10-05 |
| 91 | Local desktop readiness (#1914) | Cards #1972 (virtio-console TX, PR #1974), #1973 (M91e), #1976 (M91f, PR #1979). Automated recheck on main `efe8dd80`: Class B 11/11 gates, 59/59 boots, swift 72/72, session apps 8/8, Go rebuilds 11/11 (`verify-portable` failed on an environmental Zig 0.17 PATH issue; serial-integrity caveat filed on #1972). Owner human session 7/7 pass, verbatim "All seven pass; no findings." Persistence closed as a documented exception (receipt absent at post-session check). | ✅ 2026-10-05 |

> M73–M77 and M79–M86 also completed. Their arcs are carried in the
> **Open work** table below rather than as a dozen more rows here (`AGENTS.md`:
> keep this table compact): terminal depth #1624, TUI apps #1639, docs/site
> truth-up #1669, boot past the wall #1673, TUIOS exploration #1678, Go seat
> depth + appkit #1703. The five arcs that closed afterward — files as a
> platform #1781, the app platform #1782, time/keys/idle #1783, terminal
> graphics #1808, window chrome & UI primitives #1816 — have **closed their
> indexes** (every sub-card landed); remote framebuffer #1807 stays open on
> #1835.
>
> M40 (the gate-fleet consolidation, issue #934, done 2026-09-06) was a tooling
> workstream, not a product milestone; M36 was skipped.
>
> Issue #1338 (2026-09-15) is likewise tooling: the class-B harness now refuses
> `bash < 4.4` and treats any exit before a spec's result block as non-zero, so
> a spec that dies mid-plan can no longer be read as PASS by `fleet.sh`.

## Open work

Threads and their current state (the tracker is authoritative):

| Thread | State / next step | Cards |
|--------|-------------------|-------|
| **Go runtime port — `GOOS=virelai`** | Closed (#1163): phase 0a–0c + phase 2 netpoll + 2.1 EL0 clock landed (#1187/#1196/#1221/#1230/#1231/#1228/#1350/#1359). | #1163 |
| **M58 — Move the apps you touch** | M58a–f landed: files, GOEDIT (`go-edit`), GOTERM (`go-term`, #1307), fetch, FART. `GOCALC.ELF` (gate `go-calc`, #1378) is the CALC successor. Full-viewport via tabapp in Zig TABWM. | |
| **M60 leftovers** | Policy recorded; `EDIT.BIN`, `FILE.BIN`, `CALC.BIN`, `NOTEPAD.BIN`, `SH.BIN` (#1450), `FETCHS.BIN` (#1570), `SETTINGS.BIN` (#1565), `TOP.BIN`/`SYSMON.BIN` (#1566, one successor `GOTOP.ELF`), `VIEW.BIN` (#1567), `DOC.BIN` (#1568, successor `WEB.ELF`), and `PING.BIN` (#1573, successor `GOPING.ELF`) are gone. `TABWM.BIN` is **retained by decision** (ADR 0034 / M68c #1451) as the `settings set wm tabwm` fallback — frozen, bug-fix only. | |
| **EL0 `sys_exec` caller survival** | Closed (#1333): AddrSpaceSpec + argv on slot 28; class-B `live-el0-exec`. | #1333 |
| **Bounded native Zig portfolio** | Closed (#1880): approved target, SDK/std/streams/filesystem, Oliver render/meta, k4o render, serial offline Boris publication and actual fart-synth landed, with bounded B5/B6/B7 acceptance. No full Zig self-hosting, hosted Boris expansion or boot-default change. | #1865–#1879; [Boris final acceptance](https://github.com/drawmeanelephant/VirelaiOS/issues/1877#issuecomment-5969026402); [ADR 0038](decisions/0038-zig-guest-target.md) |
| **B5 — bounded native Zig threads** | Explicit caller-owned TLS contexts, single-use join/exit, existing capacity bounds and contended futexes; whole-second waits or precision refusal. Native acceptance: `live-el0-exec`. No std.Thread/backend or worker-budget expansion. | #1872; [ADR 0038](decisions/0038-zig-guest-target.md#b5-amendment--explicit-native-threads-1872) |
| **M71 — Seat honesty** | Closed (index #1559): seat lane + first app retirements landed: M71c–e (chrome, reopen/duplicate, freeze + start surface), M71f `GOSET.ELF` (#1565), M71g `GOTOP.ELF` (#1566), M71h `GOVIEW.ELF` (#1567), M71i `DOC.BIN` → `WEB.ELF` (#1568), M71n `GOPING.ELF` + GOSH names the net CLIs (#1573, gates `live-n1-ping`/`live-net-offline`/`go-net-clis`). M71m (#1572): exec argv is 8×256, an over-long arg is refused, GOSSHD runs `GOSH.ELF -c` directly (gate `live-ssh-server`) | #1559 |
| **M72 — Charm TUI** | Closed (#1578, all cards — M72a–d): loader bound split (`load_max` initialized / `map_max` 64 MiB mapped), window-tty VT (SGR/CUP/EL/ED/alt), Bubble Tea hello + host tape. The `u8` grid leftover moved to M73a-1. | #1578 |
| **M73 — Terminal depth** | Closed (index #1624): all 14 cards landed — M73a-1, M73f-1, M73b (#1647), M73a-2 (#1649), M73f-2 (#1651), M73c (#1627), M73e (#1652), M73g (#1653), M73h (#1654), M73i (#1656), M73j (#1636, PR #1660), M73k (#1637), M73l (#1661, PR #1666), M73m (#1662 — palette theming: `theme=custom` + `palette_fg/bg/accent` resolved at paint, chosen in GOSET, applied live). Acceptance M73z #1638 landed (class-B `go-dogfood` 4/4 — boot 04 drives the acceptance chain: tab close → launcher → GOTERM → drag-select → copy/paste/run → `tty` 0/0 → `r` resize 64x23 → lower → pixel capture; seat `maxTicks` 90 + exit sweep, `--input-key` marker-anchored delivery). | #1624 |
| **M74 — TUI apps** | Split out of M73 wave 2 (milestone 55; index #1639 closed): M74a `GOFILES.ELF` Bubble Tea file manager landed (#1644, gate `go-fileman`). | #1639 |
| **M79 — Go seat depth + appkit** | Closed (index #1703): the persistent live seat + appkit foundation and every card landed — rail chrome (M79b), sash (M79c), titles (M79d), nav kinds 9/10 (M79e), session honesty (M79g), WM_RPC wire honesty (M79h), appkit loop/dialogs (M79i), notify (M79k). | #1703 |
| **M79k — notify** | Landed (PR #1784): WM_RPC kind 12 `notify` (24-byte title is the whole text budget), a bounded 4-deep toast queue in the seat with a 3-step Surface→Bg fade over its last 3 ticks, bottom-left stack clear of the rail and the clock panel, click-to-focus through the same `focusHosted` seam alt-tab uses, and `tabapp.Notify`/`vi.Notify` with GOFILES as the adopter (a toast on a completed copy). Markers: `gotabwm: notify id=` / `notify paint id=` / `notify dismiss id=` / `notify drop n=`. `go-wm-seat` run 06 proves the chain end to end with a kind-4 snapshot pixel assert. | #1720 |
| **M79e — nav kinds 9/10** | Landed (PR #1758): the seat serves nav-declare/nav-poll, `Ctrl+Shift+[` / `]` steps per-tab history, GOFILES is the first live adopter. `go-wm-tabs` run 08 proves the round trip. `hid.go` overlaps #1747 by agreement; that claim rebases on top. | #1708 |
| **M80 — Terminal you can live in** | All 14 cards (M80a–n) landed; index #1716 closed. Landed: M80a–e, M80g, M80h, and M80k (#1727 — Ctrl+Shift+K clears the scrollback (ED 3) + snaps to tail, Ctrl+Shift+R soft reset, Ctrl+Shift+Alt+R full RIS; kernel chrome chords, `help terminal`). Later: M80f (DSR/CPR + DA replies, PR #1735), M80j (the terminal outlives its shell, PR #1737), M80l + M80m (line-editor depth + the completion menu, PRs #1731/#1732), M80n (prompt escapes, PR #1741). | #1716 |
| **M80i — font zoom** | Landed (PR #1791): one `font_size` key (small/medium/large) moves both ladders — text and the bound terminal grid (rasterized 11/13/17 px, cells 7×13 / 8×16 / 10×21), re-flows bound screens and notifies owners (WIN_RESIZE); `font` reports both ladders and sets the rung, GOSET cycles it. Class-B `live-term-depth` runs 04/05 (one snapshot per boot — the flake was root-caused and fixed (#1757)). | #1725 |
| **M81 — Files as a platform** | All 8 cards landed; index #1781 **closed** 2026-09-29. Landed: M81b (#1762 — one `mime` table: magic bytes first, extension second, printable-text last; one handler registry with GOVIEW.ELF + GOEDIT.ELF as the first two adopters. GOFILES' Enter / `l` / double-click dispatch a file and `o` lists the candidates; a type nothing opens is refused by name. `go-selftest` grew the `mime` case (write → read back → sniff → receipt), `go-fileman` run 02 the guest launch proof), M81g (#1767 — `virelai/snapshot` is a length-framed bundle whose header carries the ENTRY COUNT, so a container cut short is refused at any cut point, not just mid-entry; the seat takes one on `Ctrl+Shift+S` and restores it only against a one-shot `/host/SNAPSHOT.RESTORE`, rehydrating the share so the boot's ordinary `loadSettings`/`loadSession` do the reading. `go-wm-default` boots 05-09 are the drill: saved `bytes=321 entries=4 docs=2`, restored byte-exact (`share-equals`), corrupt → `snapshot bad header`, absent → `snapshot missing`, nothing written either way. `go-selftest` case 18 re-parses the published bundle with an independent host reader and compares every rehydrated entry to the seeded input). Also landed: M81a (trash + recent — deletes are undoable, PR #1804), M81c (the one `open` contract for paths and https URLs, PR #1800), M81d (advisory file leases, PR #1825), M81e1/e2 (crash-safe saves + the shell hook guard, PRs #1789/#1795), M81f (file watching — a change feed apps subscribe to, PR #1822). | #1781 |
| **M82 — The app platform** | All 7 cards landed; index #1782 **closed** 2026-09-29. Landed: M82a (#1768 — `image/apps.txt` is a versioned ADDITIVE schema: fields 1–4 are the v1 shape every reader already parses, and `v=` / `argv=` / `caps=` / `opens=` are trailing `key=value` fields (the shape WASM.TXT already uses). The Go seat decodes the tail and launches the row's argv, reporting `gotabwm: apps decode n=14 v=2 schema=2 argv=0 caps=5 opens=4`; `opens=` names M81b's mime types, pinned against that package. All three readers now share `sexiburger.manifest_buf_max` — the 1024 B buffers would have cut the tail rows out of the Zig seats' menus with no error), M82c (#1770 — `virelai/chords` is the global shortcuts registry: 51 rows, one owner per chord PER DISPATCH POINT (`kernel-terminal` frozen chrome / `seat` / `app/<binary>`, because focus is exclusive — GOEDIT.ELF and NOTE.ELF legally share ctrl+s). `Validate()` refuses two owners of one chord with the named `ErrChordConflict` sentence; the seat's `handleWmKey` is now a registry walk (exact mods+usage match), the seat's fail-closed prologue refuses the `/host/GOTABWM.CHORDCONFLICT` fixture and dumps the table, and GOSET's shortcuts view (ctrl+shift+h — re-bound from ctrl+shift+s at the M81g rebase, which landed the seat's snapshot arm on that chord first) shows the table. `go-wm-hid` run 08 asserts the refusal, the dump and the view). Also landed: M82b (settings pub/sub — `settings.Subscribe`/`PollChange`, PR #1801), M82d1 (the seat-hosted notifications center, PR #1830), M82d2 (DND + persistent history, PR #1843), M82e (per-app logs + crash receipts, PR #1806). | #1782 |
| **M82f — app-platform authoring chapters** | Landed: `docs/app-authoring.md` gained the app-platform chapters (manifest entry #1768, settings pub/sub #1769, chord registry #1770, notify #1771/#1785, logs + crash receipts #1772) — each with a minimal compiling example and a link to the gate that pins the seam. | #1773 |
| **M83 — Time, keys, and idle** | All 7 cards landed; index #1783 **closed** 2026-09-29. Per-card rows below. | #1783 |
| **M83g — sleep/wake contract** | Landed (PR #1805): standard VirtioFS/FUSE preserves `/host` across cross-process VZ save/restore | #1780 |
| **M83a — wall time at EL0** | Landed (PR #1838): reuses existing ADR 0007 slot 66 (`sys_time`): `vsys.Now`/`vi.Now`, GOSH `date`, GOSELF host-bounded epoch receipt; no new slot. Class-B `go-selftest`, `go-sh`, `go-help` green on the reference host. | #1774 |
| **M83b — SNTP sets the clock** | Landed (PR #1842): `time sync [SERVER]` in GOSH — one SNTP query over the UDP seam (`virelai/timesync`; no retry, 5 s budget, KoD/origin/stratum/era checks, ±1 s tick deadband), the guest clock stepped through the new **slot 78 `sys_time_set`** (ADR 0007 amendment; range 2025–2100, works on a no-epoch boot, tick count untouched). No reply, offline, bad name or bad reply exits 1 with `clock untouched`. Runner `--net-sntp-respond <ip>` / `--net-sntp-skew <s>` serve host time. `go-net-clis` boots 03 (+3600 s step, `date` reads it, one query on the wire) and 04 (no reply, clock untouched); `go-selftest` case `clock-set` (4 refusals, +100 s step, exact restore). | #1775 |
| **M83c — timezone setting** | Landed (PR #1845): one `timezone` key + shared local-time formatting (fixed offsets first). | #1776 |
| **M83d1 — translated-key contract** | Landed (PR #1803): GOEDIT's translated-key contract pinned — the probe half of the keys lane. | #1777 |
| **M83d2 — keyboard layouts** | Landed (PR #1831): a persisted `keyboard_layout` key and the seat's translation. | #1786 |
| **M83e — dead keys** | Landed (PR #1839): dead keys, compose tables, a staging buffer. | #1778 |
| **M83f — idle dim** | Landed (PR #1841): seat-owned idle dim and the visual curtain (`idle_minutes`). | #1779 |
| **M84 — Remote framebuffer** | All 6 cards landed; index #1807 **closed** 2026-09-30. M84a ADR 0037, M84b #1810 codec, M84c #1811 opt-in in-seat RFB 3.8/None on hermetic `--net` (`live-rfb`). M84d #1812 landed: every session end names its drop reason (`gotabwm: rfb drop <reason>`); `live-rfb` 6/6 pins refused auth, oversized message, wedged viewer, and a viewer RST mid-drag+mid-update / mid-focus (held press released at its last point, then local input routes). `tools/rfb-tape.sh` bridges one loopback viewer; M84e (PR #1840): the bridge speaks VNC auth (type 2, one-shot random password) to the viewer and 3.8/None to the guest, translating guest hextile to Raw because Apple's viewer advertises 13 encodings and neither hextile nor RRE. Native macOS 27.2 Screen Sharing now completes the tape — `VNC auth accepted` → `ClientInit shared=1` → `gotabwm: rfb frame` — exit 0 with a real 2560x1440 `rfb-after.png`. `--type-password` answers the viewer's own password sheet unattended. M84f (PR #1844): an over-cap SYN is refused RST+ACK in its own bounded slot, not silently dropped. Hermetic/local only. | #1807 |
| **M85 — Terminal graphics** | All 3 cards landed; index #1808 **closed** 2026-09-29. M85a #1813 picked sixel, cell-native. M85b #1814: streaming sixel decode into a pool-backed bank (≤ 96×64 px, 1 image per terminal, refused whole past a bound), image cells scroll/erase/reflow like text; corpus `image_cases`. M85c #1815: QOI `IMGCAT.ELF`, `live-term-graphics` 2-boot scanout pixels, real-scanout PNG tape. | #1808 |
| **M86 — Window chrome & UI primitives** | Landed: M86a (PR #1823) — `docs/ui-primitives.md` contract v1 (buffer model over Seam-B `[]u32`, widened `widgets.Canvas`, AA guarantees, chrome design language, 20-glyph PUA inventory). Landed after: M86b (the 20 chrome glyphs, PR #1827), M86c (the AA shape renderer + goldens, PR #1826), M86d (published canvas + appkit dialog redraw, PR #1829) — all four cards landed; index #1816 **closed** 2026-09-29. | #1816 |
| **M87 — First impressions + remote terminal** | **Closed** (index #1856, 2026-10-03; desktop journey discharged 2026-10-05). Launcher and staging landed (PR #1861). Remote class A 5/5, class B 4/4 + 3/3 + 2/2; physical-machine class C independently verified from DGX/HP connectors (2026-10-02). The human desktop journey (#1857, superseded by M91) was observed in the M91 owner session: "All seven pass; no findings." | #1856, #1857, #1858, #1859, #1860; [PR #1864 acceptance](https://github.com/drawmeanelephant/VirelaiOS/pull/1864#issuecomment-5957681032); [ADR 0022](decisions/0022-remote-console.md) |
| **M88 — JavaScript via embedded QuickJS** | **Closed** (index #1915, 2026-10-04). All cards landed: M88a #1921 (ADR 0039, ADR 0030 A2), M88b #1934 native runtime, M88c #1946 `QJS.BIN` (PR #1955), and platform fixes #1956, #1957, #1965. PR #1955 merged before a full `live-quickjs` rerun on the post-#1965 kernel. Owed: that full 23-case run on main, then owner acceptance. | #1915, #1921, #1934, #1946; [ADR 0039](decisions/0039-quickjs-runtime.md) |
| **M89 — PDF support, scoped subset** | **Closed** (index #1916, 2026-10-05). All cards landed: M89a #1920 (ADR 0040, amendment A1), M89b #1940 engine, M89c #1950 proof and corpus (PR #1954), M89d #1959 engine fixes (PRs #1960, #1967), M89e #1971 (PR #1975). CoreGraphics replaced Poppler as the outside reference — no GPL-family code ships (LGPL CairoSVG used externally for svg-raster testing only). Final PDF pair ran on a tree identical to the merge. [Acceptance](https://github.com/drawmeanelephant/VirelaiOS/issues/1916#issuecomment-5999193085). | #1916, #1920, #1940, #1950, #1959, #1971; [ADR 0040](decisions/0040-pdf-subset.md) |
| **M90 — SVG rendering** | Index #1917 **closed** 2026-10-04: owner acceptance of the bounded SVG/vector subset (ADR 0041), not full SVG or viewer integration. M90a #1919, M90b #1935, M90c #1941 (PR #1966), plus #1939, #1945, #1947. Final `live-svg-raster`: five consecutive full passes, 20/20 boots on the reference host. | #1917, #1919, #1935, #1941; [acceptance](https://github.com/drawmeanelephant/VirelaiOS/issues/1917#issuecomment-5983127246); [ADR 0041](decisions/0041-svg-raster.md) |
| **M91 — Local desktop readiness** | **Closed** (index #1914, 2026-10-05). Cards landed: #1972 virtio-console TX (PR #1974), #1973 M91e, #1976 M91f (PR #1979). Automated recheck on main `efe8dd80`: Class B 11/11 gates, 59/59 boots, swift 72/72, session apps 8/8, Go rebuilds 11/11 (`verify-portable` failed on an environmental Zig 0.17 PATH issue; serial-integrity caveat on #1972). Owner human session 7/7 pass — "All seven pass; no findings." ([write-up](https://github.com/drawmeanelephant/VirelaiOS/issues/1914#issuecomment-6002352670)). Persistence closed as a documented exception (receipt absent at post-session check). | #1914, #1972, #1973, #1976 |
| **M92 — Init and service supervision** | **Closed** (index #1985, 2026-10-10); all six cards landed. `INIT.ELF` reads declarative manifests (ADR 0042), starts services in dependency order and supervises them with restart policies, jittered backoff and M82e crash receipts; it is the boot path. M92f acceptance: a declarative boot survives a mid-boot kill. | #1985; cards #1986–#1991 |
| **M93 — Dillo-tier browser subset** | **Closed** (index #1992, 2026-10-10); all seven cards landed. M93g acceptance (PR #2067): exact-RGB8/SHA-256 live-web comparator in `tools/web-proof/compare.py`, K = 3 consecutive 36/36 runs on main — including one owner-approved deterministic `forms` render exception (`e22a69b4`). No JS still stands. | #1992; cards #1993–#1999; [ADR 0028](decisions/0028-html-renderer.md) |
| **M94 — Debugger and observability** | **Closed** (index #2000, 2026-10-10); all seven cards landed. Tracer, 100 Hz sampler (< 2%), heap analyzer, crash receipts and log viewer shipped per ADR 0043 + the ADR 0007 amendment; M94g acceptance merged. | #2000; cards #2001–#2007 |
| **M95 — Gostalgia as a guest** | **Closed** (index #2008, 2026-10-10); all seven cards landed. M95f packaging (PR #2068) shipped the static `GOSTALGIA.ELF`, APPS.TXT v2 row and launcher integration; M95g acceptance (PR #2120): run 08 journeys cold boot → seat → chord session → `fs/read` → clean shutdown, K = 5 met with 6 consecutive 8/8 passes. Overlays and `user/go/gsport/` only; Gostalgia's repo untouched. | #2008; cards #2009–#2015 |
| **M96 — Zig 0.17.0 toolchain port** | Open (index #2060); all five cards landed. Flag-day port of `build.zig`, `boot/src`, `kernel/src`, `user/src`, `user/zig` and the `zc` host corpus path from pinned 0.16.0 to 0.17.0 landed in M96c (`bfe213fd` + CI fixups); `@bitCast` audit fully dispositioned. M96d sweep: 8/8 named class-B specs + 9809/9809 unit parity under both compilers. M96e acceptance: K = 3 consecutive class-A + class-B runs green on main under the pinned 0.17 SDK — index #2060 closes by owner hand. | #2060; cards #2061–#2065; [acceptance run table](https://github.com/drawmeanelephant/VirelaiOS/issues/2065#issuecomment-6105710710) |
| **M97 — Security audit of the trust boundaries** | **Closed** (index #2069, 2026-10-11). All seven read-only audit lanes complete (#2070–#2076, findings tables on the issues); M97h consolidated ~80 raw rows into ~40 deduplicated findings routed to follow-up cards #2079–#2116 — all landed on main: PRs #2117 (Go userspace), #2118 (virtio file channel), #2119 (MM/ELF) + the m97pol/m97net/m97go/m97vf/m97mm/m97sc/m97ua lanes (PR #2137 et al). Acceptance met: consolidated table posted, every Sev-A/B owned. | #2069; cards #2070–#2077; fixes #2079–#2116 |
| **M98 — GOSH polish (daily-driver shell)** | **Closed** (index #2126, 2026-10-11); all ten cards landed: real PWD, slot-79 globbing, `cd -`/dir stack, aliases, toolbox round 2, `kill %N`/`jobs -l`/Ctrl-C, history expansion, shared contextual completion, `time`/title sync/`\?`/Ctrl-X Ctrl-E — one pure-Go `shlib` engine behind GOSH and GOTERM. M98i acceptance #2135: `go-shell-polish` — every card's leg asserted on VZ across serial-GOSH + hosted-seat journeys; fail-before misses all 21 capability legs on a pre-M98 ELF; K = 5 green (10/10 runs). | #2126; cards #2127–#2136 |
| **M98 — Agent control channel v1** | Landed: `AGENTD.ELF` serves JSON Lines on guest TCP 4747 behind an HMAC challenge; six verbs (`proc.list`/`proc.get`/`fs.read`/`fs.write`/`ui.windows`/`gosh.run`); fail-closed posture; `go-agentd` 8/8 green + class-A Go/Python suites. | #2145; [ADR 0044](decisions/0044-agent-control-channel.md) |
| **M99 — Go desktop/tooling depth (sound + networking + web typography)** | Accepted via #2194; all lanes landed. Go lane end-to-ends: `live-sound-playback` (GOSOUND WAV + notify-toast overlap, `peak=2`), `live-ssh-server` (AGENTD + two concurrent SSH sessions + WEB relay fetch on one hermetic `--net`, three distinct 5-tuples), `live-web-ttf` (`serif=truetype`, `serif-resolve=serif`, CJK through NOTOCJK, `fonts: notdef` silent). Named finding: wav-toast is intermittent under sustained PCM load (seat input/mailbox drain starvation drops keystroke bursts / loses the notify post; #2182-adjacent follow-up owed). | #2178; cards #2179–#2194 |
| **M102 — Custom-Virtio GPU 3D** | **Closed** (index #2160); all lanes landed, f2 acceptance #2171 met (`live-gpu3d` eight-leg class-B + defect fixes). Opt-in custom-Virtio Metal render device (DID `1af4:1083`, private VIR1 capset) beside native 2D: guest `GPUTRIANGLE.ELF` -> Go seat -> kernel broker -> Metal, CPU-composited into the ordinary scanout. | #2160; cards #2161–#2171 |
| **M103 — FLINT M0: agent-native SCM** | **Landed** (all four cards M103a–d): `FLINT.ELF` parses Zig/Go into Atoms (#2253), stages Ops into a flat-file store with UUIDv7 (#2251), signs and verifies Ed25519 Changes on Streams (#2252), and forks/replays/merges Streams with a semantic three-way merge on Ops, `MERGE.json` conflicts, and the `src_behind` guard (#2254); class-B `go-flint` 10/10 green. | #2253, #2251, #2252, #2254; [ADR 0049](decisions/0049-flint-scm.md) |
| **M104 — UI depth: primitives v2, widget faces, seat chrome, adoption sweep** | Open (index #2267); M104a contract v2 in review (PR #2276); cards b–h unclaimed. | #2267; cards #2268–#2275 |
| **M105 — FLINT host client (cross-platform Zig port)** | Open (index #2283); client spec in review (PR #2282); cards a–f unclaimed. | #2283; cards #2284–#2289 |
| **M106 — FLINT host server (cross-platform Zig port)** | **Landed** — all six cards closed in [flint-server](https://github.com/drawmeanelephant/flint-server) (index flint-server#1). flint-server#7 shipped the Zig 0.17 skeleton + wire model (Go field order/escaping, Ed25519 verify, torn-append JSONL, `flintd init`), `streams/` store IO with crash-safe append order, the `FLINT-SYNC/1` NDJSON server over TCP + `--stdio`, `--auth-key` HMAC challenge + `--allow-author` gating, and the `testdata/sync/` golden-transcript conformance suite; flint-client#16 landed M106e remote verbs (`push`/`pull`/`clone`, `REMOTE.json`). | flint-server#1; cards flint-server#2–#6, flint-client#9 |


## Gate status

> All class-A (portable) and class-B (VZ hardware) gates are green at HEAD.
> Gate classes are defined in [`docs/gate-inventory.md`](gate-inventory.md).
> Since M40 the class-B fleet is **discovered** from `tools/gate/specs/` via
> `tools/gate/fleet.sh`; the generated inventory is
> [`gate-fleet-inventory.md`](gate-fleet-inventory.md) (snapshot; `--check` is spec-order + locale, not a PR commit).

| Gate | Command | Result |
|------|---------|--------|
| Format | `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` | ✅ |
| Guest build | `zig build` | ✅ |
| Disk image | `zig build image` | ✅ |
| Binary + image inspect | `zig build inspect` | ✅ |
| Swift runner build | `swift build --package-path host/vm-runner` | ✅ |
| Context snapshot | `zig build context` | ✅ |
| Unit tests | `zig build test` (parallel; host suites across `kernel/`, `user/`, `test/` — the count is not script-derived, and M71i #1568 removed the 21 `lib/html` tests with their module) | ✅ |
| Class-A portable set | `just verify-portable` | ✅ |
| Class-B VZ fleet | `just verify-vz` (`bash tools/gate/fleet.sh count` = 253 members; sharded ×4 in CI + nightly once `VZ_RUNNER_LABEL` names a runner) | ✅ on the reference host; ⛔ 0 gates run in CI |
| Coordination gate | `just verify-coordination` + `just test-coordination` | ✅ |

Per-gate evidence lives in the run logs / CI. Verbose per-gate notes (M3-era
shim ladder, NVRAM console, custom-virtio, the M5 net sweep, …) are in git
history at `e5480c9`.

> Legacy M2/M20/M22/M34 scripts that are **manual-only** (not in the fleet, CI,
> or `just`; run by hand if ever needed). Each is a capability, not rot, so
> none is a deletion candidate: `verify-pointer-manual.sh` is the real-mouse
> route `hardware-contract.md` cites for the activation wall, and
> `verify-zc-corpus.sh` (+ `build-zc-host.sh`, `zc-host-link.ld`,
> `check-zc-host-contract.py`) is the host-side dual-run of the Zig dialect
> corpus that `docs/testing.md` and ADR 0035 name. Note that
> `verify-transcript.sh` is **not** on this list: `build.zig` wires it into
> `zig build test-console`, which `just verify-portable` runs.

## Assumptions & gaps (checked against merged `main`)

- **ADR 0004 console:** polled TX-only virtio-pci (DID 0x1043, BAR 0x100010000; RX followed).
- **Runner serial input:** `VZFileHandleSerialPortAttachment(nil)`; `--console` wires stdin (M1.5).
- **Memory:** `memorySize = 256 MiB`; `mem` derives from the captured map.
- **Kernel is post-`ExitBootServices` and never returns** (handoff v2 in x3, ends in a WFE loop).
- **Firmware quirks:** `ConOut` is not routed to virtio; the kernel drives the console itself. See `hardware-contract.md`.

## Multiagent coordination

Claims are **GitHub issues labeled `claim`** — one issue per piece of work,
filed before code is written. Binding rules (mirrored in `AGENTS.md`):

1. **The card IS the claim.** Claim an existing card in place
   (`just claim-card <issue>`); file a new issue only when there is no card.
   An OPEN `claim` issue is an ACTIVE claim — another agent will not duplicate
   it. The landing PR says `Closes #<claim>` so merge closes it.
2. **One editor per file at a time.** Declare every path/glob in the machine-read
   `Touches` bullet. The gate fails when two open claims from different branches
   declare overlapping `Touches` (generated artifacts are exempt).
3. **Progress and completion live on the issue.** Append comments (never rewrite
   earlier ones); close with a final evidence comment when the work lands or is
   abandoned.
4. **Heartbeats.** A comment/edit keeps a claim alive; 14+ days of silence draws
   a gate warning, ~21+ days and anyone may close it.
5. **Evidence is the gate run**, not a committed log (see `AGENTS.md`).
6. **The gate:** `bash tools/status/verify-issue-coordination.sh`
   (`just verify-coordination`, also CI) reads open `claim` issues via `gh` and
   fails on `Touches` overlaps; `bash tools/status/test-coordination.sh`
   (`just test-coordination`) tests the tooling offline.

The old file-based tracker (`docs/claims/` + `docs/logs/`) was deleted
2026-09-03; old four-digit claim numbers in prose are git-history references.

## Housekeeping conventions

- **This file is the single source of truth** for status, and stays a compact
  table. Per-card detail goes on the issue; per-arc detail goes in one
  `docs/march-m*.md` or ADR.
- **Evidence under `artifacts/`** (gitignored). No evidence ⇒ not observed.
- **Facts vs inference:** hypotheses are tagged `(inferred)`; hardware tags flip
  only with saved logs.
- **Branch hygiene:** `agent/...` branches → PR against `main` (ADR 0003).
- **New gates are declarative specs** under `tools/gate/specs/` (never a new
  `verify-*.sh`); extend an existing spec when it already covers the change.

## Related docs

- [`AGENTS.md`](../AGENTS.md) — project rules.
- [`testing.md`](testing.md) — verification sequence & evidence policy.
- [`hardware-contract.md`](hardware-contract.md) — hardware `[observed]`/`[inferred]`.
- [`architecture.md`](architecture.md) — components & data flow.
- [`gate-inventory.md`](gate-inventory.md) · [`gate-fleet-inventory.md`](gate-fleet-inventory.md) — gate classes; generated fleet inventory.
- [`archive/`](archive/) — closed-milestone detail (`status-m*-detail.md`), frozen designs, one-shots.
- Per-milestone trackers: `docs/march-m*.md`.
- Claims: `gh issue list --label claim --state open`.
