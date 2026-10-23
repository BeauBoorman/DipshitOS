# Era digest — M0 through M51

> **Condensed record (M189d, issue #3228).** This file replaces the
> M0–M51 era's per-milestone archive files: the `march-*.md` trackers, the
> `status-m*-detail.md` notes, the `roadmap-m*.md` plans, the
> `m*-*-prompt.md` / `*-design.md` one-shot agent briefs, and the era's
> `*-scoping.md` proposal cards — 123 files condensed into one digest.
>
> Their last verbatim revision is commit
> `4edfa1127671f2fc6fbfbba3dadc7664d8edeee4`; read any file as it was with
> `git show 4edfa112:docs/archive/<name>` (the same preserve-by-reference
> pattern `docs/status.md` uses for the M17–M51 gate-by-gate narrative at
> `e5480c9`). If a code comment or old doc still names one of the
> condensed files, this digest is the lookup: file name → milestone →
> `git show` line.
>
> Nothing here is an active plan or a current contract. The live,
> always-current version of "what each milestone proved" is the
> [`docs/status.md`](../status.md) table; the binding contracts are the
> ADRs under [`docs/decisions/`](../decisions/).

Numbering note: **M36 was skipped; M40 was a tooling workstream**
(gate-fleet consolidation, issue #934), not a product milestone — so the
table jumps M35 → M37 and M39 → M41. M44, M46, M48, and M49 produced no
per-milestone archive files; their records are the status.md row, the
ADR, and the umbrella issues it names.

## Milestones

| M | What it proved | Condensed record (each file at `4edfa112:docs/archive/…`) |
|---|----------------|-----------------------------------------------------------|
| 0 | Boot pipeline — a Zig AArch64 UEFI app on a FAT32 ESP boots under real firmware (`\BOOTED.TXT`) | `roadmap-m0.md` |
| 1 | Kernel handoff — `KERNEL.BIN` loaded, jumped to, returned; ADR 0002 | `roadmap-m1.md`, `m1-kernel-handoff-prompt.md` |
| 1.5 | Interactive kernel monitor — live serial console TX+RX; tag `m1.5-interactive-monitor` | `march-m15.md` (the M1.5 tracker — M15's own tracker is `march-m15-audio.md`), `roadmap-m1.5.md` |
| 2 | Kernel proper — `ExitBootServices`, captured EFI map, identity TTBR0_EL1, MMIO serial + polled TX console; ADR 0004 | `roadmap-m2.md`, `m2-kernel-proper-design.md`, `m2-kernel-proper-prompt.md`, `m2-bad-handoff-fix-prompt.md`, `m2-vz-serial-gate-prompt.md` |
| 3 | Allocator, interrupts, tasks — physical allocator, GIC+timer, tasks, EL0/SVC, syscall ABI 0–4, uaccess, per-task TTBR0 | `march-m3.md`, `status-m3-detail.md`, `roadmap-m3.md`, `m3-march-tracker-prompt.md`, `m3-syscall-abi-prompt.md`, `m3-runner-scripted-input-prompt.md`, `m3-ragshit-dogfood-prompt.md` (its recorded output survives — see "What stayed") |
| 4 | Real randomness — virtio entropy + ChaCha20 CSPRNG, ASLR, DATA partition, process abstraction | `march-m4.md`, `status-m4-detail.md`, `roadmap-m4.md`, `m4-*-prompt.md` ×15 (entropy, process abstraction, IPC, exec-args, wait/exit, kill, pools, concurrency, general-FS) |
| 5 | Networking — virtio-net TX/RX, ARP, IPv4, UDP, NAT, DHCP, TCP + retransmission | `march-m5.md`, `status-m5-detail.md`, `roadmap-m5.md`, `m5-*-prompt.md` ×7 (arp, ipv4, net-rx, net-tx, net-outbound, udp, udp-syscall) |
| 6 | Graphics — virtio-gpu (1280×720), text, Road Pops, Driving Award WM, draw syscalls 12–15 | `march-m6.md`, `status-m6-detail.md`, `roadmap-m6.md`, `m6-gpu-prompt.md`, `m6-text-prompt.md` |
| 7 | Input — Apple XHCI + HID keyboard/pointer, event FIFO → line editor | `march-m7.md`, `status-m7-detail.md`, `roadmap-m7.md` (also carried the cross-milestone virtio device-surface table) |
| 8 | Usability (ADR 0008) — grouped help, line editor/history, error contract, HIG, motd/about/sysinfo/settings | `march-m8.md`, `status-m8-detail.md`, `roadmap-m8.md` |
| 9 | App events (ADR 0009) — per-process event queues, `sys_poll_event`/`sys_wait_event` | `march-m9.md`, `status-m9-detail.md`, `roadmap-m9.md` |
| 10 | Userland FS (ADR 0010) — per-process file table, path canon, slots 23–27 | `march-m10.md`, `status-m10-detail.md`, `roadmap-m10.md` |
| 11 | Desktop (ADR 0011) — `ui.zig`/font8x8 toolkit, first apps, exec/kill | `march-m11.md`, `status-m11-detail.md`, `roadmap-m11.md` |
| 12 | Net apps (ADR 0012) — TCP slots 30–33, DNS/fetch/chat clients | `march-m12.md`, `status-m12-detail.md`, `roadmap-m12.md` |
| 13 | Files & apps — mutating FS, APPS.TXT manifest, FILE.BIN | `march-m13.md`, `status-m13-detail.md`, `roadmap-m13.md` |
| 14 | Shared services — clipboard, app timers, NOTEPAD composition, hardening | `march-m14.md`, `status-m14-detail.md`, `roadmap-m14.md` |
| 15 | Audio — virtio-snd (DID 0x1059), PCM playback, `sys_audio` 42–45 | `march-m15-audio.md`, `status-m15-detail.md`, `roadmap-m15.md`, `m15-*` ×5 (commands design/prompt, host-plumbing, postmmu-t0sz experiment, shell-core design) |
| 16 | Kernel grows up — DSK3 segmented image, guard pages, grown pools | `march-m16.md`, `status-m16-detail.md`, `roadmap-m16.md` |
| 17 | Desktop completeness — C1–C10 + Arc1–5: widget depth, window management, app upgrades, polish | `m17-desktop-completeness.md`; Arc2's tracker under "Cross-milestone" below |
| 18 | Terminal & shell depth — T1–T16: scrollback, selection, search, persistent history, colors, scripting | `march-m18.md` |
| 19 | Shell programming — P1–P16: pipes (56/57), redirection, env, functions, substitution, arithmetic, conditionals | `march-m19.md` |
| 20 | Text & Unicode — U1–U5: font sizes, Unicode glyphs, search, chrome, tabs | `march-m20.md` |
| 21 | Window depth — W1–W16: tiling, minimize, alt-tab, notification center, maximize, focus rings | `march-m21.md` |
| 22 | Developer tools — D1–D16: ELF loader, assembler, symbols, disassembler, strace, ps, dmesg | `march-m22.md` |
| 23 | The text editor — E1–E25: EDIT.BIN, undo/redo, goto, tabs, syntax, console split | `march-m23.md` |
| 24 | CALC grows up — K1–K16: programmer mode, memory, units, constants, history | `march-m24.md` |
| 25 | File manager depth — F1–F18: du, sort, overwrite/conflict, path copy | `march-m25.md` |
| 26 | Network experience — N1–N16: ping, netstat, traceroute, HTTP fetch, download mgr | `march-m26.md` |
| 27 | Desktop polish — G1–G30: splash, wizard, previews, sounds, sysmon, tooltips, audits | `march-m27.md` (the M27 dogfood report survives — see "What stayed") |
| 28 | SMP — PSCI CPU_ON bringup, per-core schedulers, spinlocks, GICv3 SGI IPIs | `march-m28.md` |
| 29 | VM depth — demand paging, COW page sharing, anonymous mmap, zero-leak teardown | `march-m29.md` |
| 30 | Dynamic linking — freestanding `LD.SO`, `LIBUI.SO`/`LIBFONT.SO`, W^X multi-aperture | `march-m30.md` |
| 31 | Dyn-linking ecosystem — CALC/NOTEPAD/FILE/DESKTOP → `.ELF`, runtime `dlopen`/`dlsym` | `march-m31.md` |
| 32 | WM server migration — Seam A: desktop policy to a userland WM server (slot 65), kernel slimmed WMS1–WMS9 | `march-m32-wm-migration.md` |
| 33 | Seam B — full pixel ownership: shared-anon mmap, apps own buffers, WM composes one present | `march-m33-seam-b-pixel-ownership.md`, `wms10-seam-b-scoping.md` |
| 34 | FAT-free storage — host file channel HF1–HF7 (custom-virtio); FAT removed; CLONE dedup; binding ABI is ADR 0007 | `host-file-channel-scoping.md` |
| 35 | WASM core interpreter — `WASM.BIN`, frozen `env.*` surface, `wc` capstone; contract is `docs/wasm-import-contract.md` (live) | `march-m35-rust-author-proof.md`, `march-m35-w4-core-completeness.md`, `march-m35-w5-wc-capstone.md`, `wasm-core-scoping.md` |
| 37 | Desktop quality pass — God Menu overlay, tab strip render + mouse, design tokens, snap guides | `march-m37-desktop-quality.md`, `desktop-quality-scoping.md` |
| 38 | Vector typography — TrueType Inter/Fira Code, anti-aliased BGRA, proportional metrics | `march-m38-gui-typography.md` |
| 39 | Tabbed desktop & modular UI — modular `ui.zig`, rounded rects, `TABWM.BIN`, tab lifecycle | `march-m39-tabbed-desktop.md` |
| 41 | Test separation — parallel `zig build test`, shared mocks, de-monolithized source | `march-m41-test-separation.md` |
| 42 | The Sexiburger desktop — mascot raster, WM→app resize seam, `lib/tabapp.zig`, full-viewport | `march-m42-sexiburger-desktop.md` |
| 43 | Device depth (USB) — XHCI bulk engine, USB mass storage (BOT+SCSI), `.usb` block seam | `march-m43-device-depth.md` |
| 44 | Terminal (vt) seam — `/dev/tty` device file, `sys_tty_attach` slot 67; ADR 0020 | — (status.md row + ADR 0020 only) |
| 45 | Userland shell & front-ends — `tty.zig` editor, `SH.BIN`, `TERM.BIN`, net front-end, default-shell flip; ADR 0021 | `march-m45-userland-shell.md` |
| 46 | Remote access Stage 0/1 — `--console-tcp`, guest net auth; ADR 0022 | — (status.md row + ADR 0022 only) |
| 47 | Crypto primitives — SHA-256/512, HMAC, ChaCha20, Ed25519; ADR 0023 | `crypto-scoping.md` |
| 48 | Browser-style tab depth — rail-native tabs: reopen/duplicate, reorder, pin/group; umbrella #1120 | — (status.md row + issues only) |
| 49 | A shell I'd use daily — `monitor` detach, startup contract, `toolbox.zig` multicall | — (status.md row only) |
| 50 | Trust & isolation — uid/caps, permissions, secrets, authenticated remote; ADR 0024 | `trust-scoping.md` |
| 51 | SSH — userland SSH-2 client `SSH.BIN`, real-OpenSSH interop; ADR 0025 | `ssh-scoping.md` |

## Cross-milestone records

| Record | Span | File (at `4edfa112:docs/archive/…`) |
|--------|------|-------------------------------------|
| Arc2 tracker — the window-management arc deferred past M17 (drag-resize, context menus, tray) | M17-era arcs | `march-arc2.md` |
| Post-Arc5 forward roadmap — "the experience layer" plan | M18–M27 | `roadmap-post-arc5.md` |
| Agent concurrency plan — lane assignments for parallel agent work | M19–M27, dated 2026-08-22 | `agent-concurrency-plan.md` |
| Multi-agent concurrency gameplan — board-level who-touches-what | 2026-09-01 board | `concurrency-gameplan.md` |

## What stayed in `docs/archive/`, and why

Not everything old condensed — these survive as files, not pointers:

- **`ragshit-0176/` and `m3-ragshit-bundle.md`** — raw recorded
  gate/dogfood output. They are evidence, not prose: the archive
  convention keeps them byte-identical.
- **`dogfood-m27.md`** — the M27 dogfood & completeness sweep report;
  point-in-time verification evidence (issues #444–#473).
- **`line-of-sight.md`** — retired board view whose Z-ladder and
  dialect-boundary sections are still cited by
  `tools/verify-zc-corpus.sh`, `tools/build-zc-host.sh`, and ADR 0035.
- **`html-renderer-scoping.md`** — post-era design card (M71i) whose
  decisions ADR 0028 fixes and cites.
- **`gate-inventory-detail.md`, `hardware-contract-detail.md`** — frozen
  verbatim detail spills that the live `docs/gate-inventory.md` and
  `docs/hardware-contract.md` still point into.
- **`calm-lavoisier-memorial.md`, `dipshitos-name.md`** — project lore,
  not plans.

## Reading the verbatim record

```bash
# any condensed file, exactly as it last stood:
git show 4edfa112:docs/archive/march-m3.md

# the era file set that fed the digest:
git ls-tree -r --name-only 4edfa112 docs/archive/ | grep -E 'march|roadmap-m|status-m|-prompt|-design|scoping'
```

Pre-condensation history is in git, per file, the usual way
(`git log --follow`). The `e5480c9` commit additionally preserves the
pre-compaction M17–M51 `docs/status.md` narrative named in the live
status file.
