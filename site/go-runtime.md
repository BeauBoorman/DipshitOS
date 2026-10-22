---
title: The Go runtime
parent: architecture
status: published
tags: [architecture, go, userland, toolchain]
---

# The Go runtime

VirelaiOS runs real Go — the gc toolchain, the real runtime, goroutines,
channels, and a working slice of the standard library — at EL0 on a kernel
that has never heard of POSIX. `GOOS=virelai` is a genuine port: the Go
runtime speaks the kernel's own syscall ABI directly, and the binaries it
produces are the operating system's userland, not guests inside a
compatibility layer. This page is the story of why that choice was made,
what the port actually does, and how far the guest has gone toward building
itself.

## Why Go owns userland

The language split is a product decision, recorded in
[ADR 0030](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0030-go-is-el0.md):
**VZ is the hypervisor, Zig is the guest kernel, Go is EL0.** Zig keeps
`boot/`, `kernel/`, the virtio drivers, the GIC, the scheduler, the syscall
table, the Swift runner, and the serial monitor. Everything a user
touches — the seat, the chrome, the apps, the shell — is written once, in
Go, as statically linked `GOOS=virelai` ELFs.

The forcing fact was demonstrated before the policy was written: a Go
program owning a raw kernel window (`GOWIN.ELF`, gate `go-win`) and an
independent Go renderer painting in-guest (`WEB.ELF` over
`user/go/webrender`) both landed with the kernel untouched. After that,
every new Zig userland program was a second product in the wrong language.
The migration was mechanical and reversible — one binary at a time, each
deletion independently revertible, never a flag day. The retired Zig
`EDIT.BIN`/`FILE.BIN`/`CALC.BIN`/`NOTEPAD.BIN`/`SH.BIN`/`FETCHS.BIN` were deleted as their Go successors landed;
the one deliberate survivor is `TABWM.BIN`, retained by decision ([ADR
0034](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0034-tabwm-retained-fallback.md))
as the `settings set wm tabwm` fallback seat. The compiled default has
been `gotabwm` since the M59 flip — a boot with no persisted seat setting
autostarts `GOTABWM.ELF`, pinned by `just gate go-wm-default`.

The contract between the languages is **ABI and formats, never
libraries.** There is no cgo and no FFI: a Go program speaks the
[[userspace|ADR 0007 syscall table]] and the WM_RPC wire exactly the way a
Zig program did, and the shared files (`SETTINGS.TXT`, `APPS.TXT`, the
`.tabs` session format) are parseable by both sides. A leftover Zig binary
is something you `exec`, not something you link — which is why unmodified
Zig apps still run inside the Go seat today.

## The port itself

Upstream Go has no third-party-GOOS mechanism: `GOOS=none` was declined
and the overlay proposal is still unaccepted, so every non-POSIX port —
Fuchsia, TamaGo, z/OS — is a maintained fork, and this one is too.
[ADR 0026](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0026-go-runtime-port.md)
fixes the shape: **a fork of the gc toolchain, never a Linux-syscall skin
and never TinyGo.** A Linux skin would import Linux ABI semantics —
sigaction, clone flags, Linux errnos — that this kernel explicitly
rejects, and TinyGo is not the gc runtime (no `plugin`, broken
`os/signal`/`os/exec`, a different GC).

The fork's maintenance surface is deliberately small: a handful of source
edits plus GOOS-gated files, applied by
[`tools/go/overlay/`](https://github.com/drawmeanelephant/VirelaiOS/tree/main/tools/go)
to a copy of a stock Go distribution kept as a sibling checkout
(`../go-virelai`, the same convention the FLINT ports use). Rebase per Go
release is hours of work; the conflicts concentrate where every port's
conflicts concentrate.

## What the runtime does at EL0

**Syscalls, unmediated.** The runtime issues `svc #0` with the slot number
in x8, arguments in x0–x5, the result in x0 — the kernel's own errno
encoding, with no translation layer. The `syscall` and `os` packages were
authored fresh for this GOOS, the way any non-Unix port authors them: a
wasip1-shaped port layer mapping `os.File` onto the kernel's handle-cursor
file ABI, including a positional shadow that answers `Pread` and `Seek`
over a channel that is append-and-cursor only (bounded, and refusing
`ENOSYS` past its window rather than lying about offsets).

**Memory is sbrk.** Go's `mem_sbrk` platform, build-tagged for virelai,
maps the heap contiguously through `sys_mmap` with address hints — the
kernel honors page-aligned hints, so the runtime gets Linux-`brk`
semantics, demand-backed, with zero kernel-side heap machinery. `mmap`
regions are registered process-wide: the sbrk heap one M reserves is
visible to every M, because `arm_task_regions` merges the process registry
into each task's uaccess view at SVC entry.

**Time is a register read.** `nanotime` is `CNTPCT_EL0` scaled by a
per-boot multiplier computed in `osinit` — no clock syscall on the hot
path, because the counter is already EL0-readable. `walltime` adds the
slot-66 boot epoch to monotonic elapsed. Go's time machine on VirelaiOS is
two instructions and a multiply.

**Threads are real kernel tasks** ([ADR
0027](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0027-go-threads-futex.md)).
Slot 73 `sys_thread` creates a task bound to the caller's *process* — one
address space, one file table, one principal, many tasks — and slot 74
`sys_futex` gives bounded wait/wake on a user word for `semasleep` /
`semawakeup`. A Go M maps 1:1 onto a kernel task; the process dies when
its last task exits (`exit_group` semantics, no join — Go joins via
channels anyway, which is the runtime's own model). The five `proc.go`
fork deltas that phase-0a needed — sysmon off, template thread skipped,
spare-M handoffs dropped — were all retired when the slots landed; the
scheduler surface is stock upstream Go again. `GOMAXPROCS=2` is the real
runtime setting, not a gate hack, and the bound underneath everything is
the task pool (raised 16 → 64 when guest RAM went to 512 MiB): an over-cap
`sys_thread` refuses `EAGAIN` by name, which the runtime surfaces as the
named `newosproc` refusal, never a wedge. `just gate go-goroutines` and
`go-stress` pin both the happy path and the refusal shape.

**Netpoll rides the socket seam.** The runtime's poller parks on slot 76
`sys_sock_ready` against the slot-80 bounded socket table — a
listener/connection table with named `ENOSPC` refusal rather than the old
single-connection singleton — so `net.Dial`-shaped Go code and the `vi`
network calls share one honest substrate. `vi.Dial` is what `flint push`,
`GOSSH.ELF`, and the HTTPS clients all open.

**Faults deliver.** Phase 0c wired EL0 fault delivery into `sigtrampgo`
through slot 75 `exnotify`: a Go panic produces a traceback and a named
tombstone, and `go-panic` pins it.

<Aside kind="info">

**VERIFIED.** The port's bring-up is a class-B fixture: `just gate
go-hello` execs `GOHELLO.ELF` and asserts the console path, sbrk growth, a
full GC cycle and clean exit on serial — plus, in later runs, the
streamed-exec and loader-bound legs described below.

</Aside>

## The loader contract

A `GOOS=virelai` binary is a gap-layout static ELF: at most three PT_LOAD
segments ordered R+X / optional R / RW, W^X enforced, every segment mapped
at its declared virtual address. The exec path for that shape does not
stage the whole file — it reads a 16 KiB header window, validates each
segment's file range against the volume's own STAT size, then streams
bytes straight into the physical pages they will occupy. That is the
[ADR 0035](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0035-selfhost-exec-bound.md)
K1 move: a 9.5 MiB Go image (8.4 MiB of it initialized data) now execs
and reads its own payload back, where every other image shape is still
bounded by the 2 MiB staging buffer.

Two bounds name what they charge, and each refusal names its bound:

| Bound | Charges | Value | Refusal |
|-------|---------|-------|---------|
| `exec_image_max` | the file itself, any shape | 32 MiB | `image_too_large` |
| `load_max` | `Σ p_filesz` — initialized bytes off the volume | 32 MiB | `segment_too_large` |
| `map_max` | `Σ p_memsz` — virtual span claimed | 64 MiB | `map_too_large` |
| staging buffer | shapes that still transit the fixed 2 MiB copy | 2 MiB | `staging_too_large` |
| truncation | file shorter than its headers promise | — | `image_truncated` |

The `load_max`/`map_max` split exists because zero-initialized
`.bss`/`.noptrbss` costs no file bytes: the FIPS scratch buffer every
Charm-sized binary drags in is 32 MiB of `.noptrbss`, and a bound named
for *file* bytes was refusing images the file could not even hold. Since
the demand-zero tail landed, `map_max` is honestly a virtual bound — an
untouched `.bss` page costs no RAM until it is written — and the exec
line reports `datapages=` (resident) beside `mappedpages=` (virtual).
`just gate go-hello` pins all of this: the 9.5 MiB exec, the 40 MiB
`.bss` tail read end to end, and the 1 GiB `p_memsz` image refused as
`map_too_large` with the staging-buffer sentence absent.

## The SDK surface

`user/go/` is both the product fleet and the SDK it is written against —
a single `go.mod` workspace of `virelai/*` packages. The load-bearing
ones:

| Package | What it provides |
|---------|------------------|
| `vi` | The syscall SDK: files (`ReadFileAll`, `WriteFileSafe` = temp + fsync + rename), `Dial`/`Listen` + DNS, windows and the WM_RPC wire, `Exec`/`Wait`/`Procs`, `mmap`, audio, timers, `Now`/`Nanos`, `Random`, secrets, the grant-admin surface |
| `vsys` | Lower-level console/sys glue beneath `vi` |
| `tabapp` | The tab-client framework every hosted app runs on: window lifecycle, canvas, notify toasts, session save/restore |
| `widgets`, `appkit` | The widget set (text/button/list) and the kit layer — dialogs, `FilePicker`, `Progress`, `ErrorBanner`, menu bar/tree/table controls |
| `draw`, `icons`, `theme` | Depth primitives, the chrome glyph inventory, palette/theming |
| `shlib` | The pure-Go shell engine behind `GOSH.ELF` and `GOTERM.ELF` — parse, builtins, completion — plus `netauth` and the secret-store reader |
| `webrender`, `css`, `webstyle`, `ttf` | The Dillo-tier engine behind `WEB.ELF` and its typography |
| `pdf`, `svg`, `flate` | The bounded PDF and SVG subsets and the shared inflater |
| `ed25519`, `sshlib`, `tls`, `dns` | The protocol shelf: RFC 8032 vectors, the SSH wire/client/server crates, TLS 1.3, resolver |
| `chords` | The global-shortcut registry — one owner per chord per dispatch point, `ErrChordConflict` refusals |
| `snapshot` | The length-framed bundle format the seat's save/restore rides |
| `timesync` | The SNTP client behind `time sync` (slot-78 `sys_time_set`) |
| `mime` | The one magic-bytes-then-extension table + handler registry |
| `infer`, `goinfer` | The bounded Metal-compute inference surface behind `GOINFER.ELF`/`GOASSIST.ELF` |
| `hostint` | The consented host-integration lanes (signed VHI1 records) |

The fleet itself — `GOSH.ELF`, `GOEDIT.ELF`, `GOFILES.ELF`, `GOTERM.ELF`,
`WEB.ELF`, `GOCALC.ELF`, `GOTOP.ELF`, `GOSET.ELF`, `FLINT.ELF`,
`STORE.ELF`, `AGENTD.ELF`, `GOBUILD.ELF`, `INIT.ELF` and two dozen more —
is what `image/apps.txt` and `fleet.txt` pin. Every entry there is
compiled by this toolchain and gated by a spec that boots it.

## The in-guest toolchain

The moonshot that made this more than a port: `cmd/compile` and `cmd/link`
are ordinary Go programs, so they were built for `GOOS=virelai` and they
**run in the guest** as `GOCMDCOMPILE.ELF` and `GOCMDLINK.ELF`. Getting
them there took three recorded moves:

- **The exec bound moved** (K1 above) — the toolchain's ~24 MiB
  `cmd/compile` image is an order of magnitude past the old staging bound.
- **A toolchain-scoped FIPS gate** — one build tag (`virelaitoolchain`,
  passed only for the two toolchain images) excludes the 32 MiB FIPS
  scratch buffer from *those* images only; guest apps keep the real
  source.
- **A positional-I/O port layer** — `cmd/internal/bio` seeks on package
  archives and patches output headers, and the kernel's file ABI is a
  cursor, not a random-access device. The port shadows reads and stages
  writes until `Fsync`/`Close`, refusing past its 16 MiB window by name.

`GOVIRELAI_STD=1` — a fork-local `GOOS=virelai make.bash` std install —
stays deliberately opt-in: nothing in the loop reads a virelai `pkg/`
tree, so the flip would only tax every guest build. And the boundary
[ADR 0035](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0035-selfhost-exec-bound.md)
D4 names is still real: **the toolchain payload is host-produced and
host-staged.** `tools/go/stage-selfhost.sh` places `GOIMPORT.CFG`,
`GOPKGS.TXT`, and ~15 MiB of `GPKG_*.a` package archives on the share; the
guest compiles and links against those. There is no `go` command in the
guest — `os/exec` is honestly `ENOSYS` — so the build driver is
`GOBUILD.ELF`, which sequences compile-then-link children through
`vi.Exec`/`sys_wait` the same way the shell does, every intermediate a
file on `/host`. There is no in-guest `cmd/asm`: the handful of
virelai-tagged `.s` gateways keep `needs_asm` as their named exclusion.

## Self-hosting, measured

M112 closed the loop — **the guest builds, tests, and releases its own
fleet** — and the numbers are pinned, not aspirational:

- **`GOBUILD.ELF fleet`** builds the pinned 19 rows of
  [`user/go/gobuild/fleet.txt`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/user/go/gobuild/fleet.txt)
  in-guest: **15 built, 4 named refusals** — `GOFILES`, `PULSE` and
  `GOHELP` refuse `dep_unsupported` (their closures want packages outside
  the staged table) and `GOSTALGIA` refuses `external_tree` (its sources
  live in a pinned external checkout). A refused row names its reason in
  `FLEET.MF`; nothing is silently skipped.
- **`GOBUILD.ELF test`** runs the pinned package suite in-guest: **47 run
  rows, 796 tests**, receipts on the share, every non-run package named in
  `testpkgs.txt` with its exclusion reason.
- **`GORELEASE.ELF assemble`** writes a GPT/FAT32 boot image in-guest —
  `user/go/release` is a byte-exact port of `image/mkfat32.py`, and the
  gate proves it by building the reference image from the same inputs and
  comparing bytes — then the host **boots the guest-built image** with
  the guest-built bundle armed as the share, and every manifest row
  smoke-execs.

`just gate live-selfhost-go` and `just gate live-release` are the standing
class-B proofs, each held at K=5 consecutive greens on the reference host.

## The bounded Zig exception

Go owns EL0 — with one closed, owner-approved exception. [ADR
0038](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/decisions/0038-zig-guest-target.md)
grants a **bounded native Zig portfolio** for four named workloads:
Oliver (native proof + render/meta CLI), k4o (template/JSON render), Boris
(the serial, offline compile-and-publish artifact that builds this site),
and the actual fart-synth deterministic synthesizer. Each workload has
approved numeric budgets — input/output bytes, one bounded mmap arena,
named refusal vocabulary (`InputLimit`, `OutputLimit`, `HandleLimit`, …)
— built by the pinned stock compiler against a materialized private
stdlib overlay selected with `--zig-lib-dir`, targeting
`aarch64-freestanding-none` (a recipe, not an upstream OS tag). B5 added
bounded native threads: explicit caller-owned TLS, single-use join/exit,
no `std.Thread` backend.

What the exception is *not*, stated because the ADR states it: no new Zig
GUI, no second toolkit, no Go↔Zig FFI, no full Zig self-hosting or hosted
`zc` expansion, and no boot-default change. The gates are `live-oliver`,
`live-k4o`, `live-boris`, and `live-zig-fart`.

<Aside kind="warning">

**LIMITATION.** The honest edges: no cgo or FFI anywhere; `os/exec` is
`ENOSYS` (a driver program, not `cmd/go`, sequences builds); async
preemption stays off, so STW is cooperative (the wasip1/Fuchsia caveat —
a call-free tight loop delays it); wall time resolves to one second; the
toolchain payload is host-staged, so "self-hosting" ends at the point
where the guest builds and releases *this* fleet — the compiler binaries
themselves are still produced by the host fork build.

</Aside>

## Where next

- [[userspace|Userspace & syscalls]] — the ABI the runtime speaks.
- [[processes|Processes & IPC]] — task, thread and lifecycle detail.
- [[memory|Memory model]] — the demand-paging machinery under `mem_sbrk`.
- [[devloop|The in-guest dev loop]] — what the toolchain enables.
- [[trust|Trust & security]] — grants, measured exec, and the secrets the SDK reads.
- [[programs|Programs & apps]] — the fleet the SDK serves.
