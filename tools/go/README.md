# tools/go — the GOOS=virelai gc toolchain fork

Issue #1163 (phase 0a). This directory holds the **source of truth** for
VirelaiOS's Go support: an overlay + a set of small source edits applied to
a stock Go distribution, producing a `GOOS=virelai GOARCH=arm64` gc
toolchain. No POSIX, no libc, no Linux ABI — the runtime talks to the
kernel through the ADR 0007 `svc #0` seam only.

## Why a fork

Upstream Go has no third-party-GOOS mechanism (golang/go#35956 declined
`GOOS=none`; golang/go#73608's `GOOSPKG` overlay proposal is still open).
Every non-POSIX port (Fuchsia, TamaGo, IBM z/OS) is a maintained fork
tracking each release. The maintenance surface here is deliberately tiny:
**6 file edits + 8 new GOOS-gated files** (proc.go's phase-0a thread gates retired in 0b round 2, ADR 0027; signal_virelai.go is phase 0c, #1228; the phase-2 edit is `apply.sh` step 3h, which widens `runtime/netpoll.go`'s build tag so the platform-independent poller core compiles for virelai; the M95-prerequisite edit is step 3g6b, which widens the stock `net` POSIX-plumbing tags so `net` compiles — every external operation still refuses at `socket()`, #2029); everything else is stock.

## Layout

| Path | Role |
|---|---|
| `overlay/runtime/os_virelai.go` | the GOOS layer: osinit, write1, exit, time, readRandom, goenvs, futex-backed lock_sema, sbrk over sys_mmap (the signal surface moved to signal_virelai.go in 0c) |
| `overlay/runtime/signal_virelai.go` | phase 0c (#1228): initsig registers sigtramp via slot 75, virfaulthandler arms sigpanic, crash() exits through the syscall |
| `overlay/runtime/sys_virelai_arm64.s` | the syscall gateway: `svc #0` with x8=slot (ADR 0007), CNTPCT_EL0 nanotime |
| `overlay/runtime/rt0_virelai_arm64.s` | entry (`_rt0_virelai_arm64`): argc/argv block → SysV argv array + envp (issue #1226) |
| `overlay/runtime/netpoll_virelai.go` | phase 2 (#1163): the REAL integrated poller (netpollinit/open/close/arm/poll/break) driving slot 76 `sys_sock_ready`; the parked G comes back through stock `netpollready -> netpollunblock -> goready` |
| `overlay/internal/goos/zgoos_virelai.go` | generated GOOS consts (gengoos shape, hand-applied) |
| `overlay/net/net_virelai.go` | #2029: the `net` platform leaf layer — `netFD` + every socket-shaped hook refuses `ENOSYS` (there is no socket slot to fill), so `net.Pipe`/`net.Conn`/`net.Listener` compile and in-process IPC works while dial/listen/DNS/interfaces refuse with named errors |
| `apply.sh` | copies a stock distribution + applies everything, idempotently, committing a git delta in the fork |
| `build-go.sh` | runs the host make.bash pass on first use (the cross-std pass is `GOVIRELAI_STD=1` opt-in for phase 2), then links programs with `-ldflags "-s -w"` at the Go default base (the gap loader maps at declared vaddrs; stripped to fit the 2 MiB exec staging bound) |
| `goread.go` | M70c (#1455): reads a multi-MB file out of the host share end to end at the EL0 read cap (2048 B/call) and reports the rate — `go-hello` run 04 asserts the byte count, the call arithmetic and the FNV hash of the bytes READ against the file on macOS, and ADR 0035 amendment 2 records the measured transfer (~30 MB/s, ~15,300 calls/s) |
| `gosyscall.go` | M70c-S1P/S1L (#1525, #1540): the first fixture whose file I/O goes through the **standard library** — `fmt` into `os.Stdout`, `os.Open`/`Read`/`Mkdir`/`WriteFile`/`ReadFile`/`ReadDir`/`Stat`/`Remove` over the ported `syscall`+`os`. `go-hello` run 05 asserts its own output against the staged file on macOS (32-bit FNV of the 9.5 MiB image) and checks the removes from the host side; it needs the runtime's break-base floor (amendment 4) to run at all |
| `gonetrate.go` | M179a (#3147): the network throughput bench fixture — dials the `--net` relay endpoint and moves a deterministic 4 MiB stream (`rx` reads it and verifies the checksum guest-side; `tx` writes it for the host sink's byte-count + FNV check), timed with `vsys.Nanotime` like `goread`. `live-bench`'s net-rx/net-tx rows read the `gonetrate: rate dir= ... kib_s=` line |
| `hello.go` / `goargs.go` / `goroutines.go` / `gostress.go` / `gopanic.go` / `gonet.go` | the class-B fixtures: console + sbrk heap growth + a full GC cycle; raw-ELF argv+envp (`GOMAXPROCS` override); goroutines + futex + the cross-core proof; 0b breadth (GC/channel/timer/futex, issue #1227); 0c fault delivery + recover + traceback (issue #1228) |

## Prerequisites

- A stock Go 1.27.1 distribution (Homebrew default:
  `/opt/homebrew/Cellar/go/1.27.1/libexec`, or point `GOROOT_STOCK` at it).
- `rsync`, `gsed` (GNU sed — see AGENTS.md's env-check note).

## Usage

```bash
bash tools/go/apply.sh            # create/patch the fork (../go-virelai)
just go-toolchain                  # builds .build/go/{GOHELLO,GOARGS,GOROUT,GOSTRESS,GOPANIC,GOBIG,GOREAD,GOSYSCALL,GOSELFHOST}.ELF
just gate go-hello                 # class-B VZ gate: fixtures (runs 01-05), the guest's
                                   #   own toolchain (06-08), the daily loop (09-10)
just gate go-args                  # class-B VZ gate: raw-ELF argv + envp / GOMAXPROCS
just gate go-goroutines            # class-B VZ gate: threads/futex + cross-core
just gate go-stress                # class-B VZ gate: GC / channel / timer / futex breadth
just gate go-panic                 # class-B VZ gate: fault delivery + recover + traceback
bash tools/go/build-netdiag.sh     # builds GONETSTAT/GODNS/GOTRACEROUTE.ELF for M78a
```

The network-diagnostics recipe requires the already provisioned GOOS=virelai
fork. Its three live specs stage the prebuilt ELFs; it does not auto-build the
fork inside gate runs.

**The Go-runtime gates are not hermetic**: `just verify-vz` includes them,
and each refuses to run (honest setup failure) until
`just go-toolchain` has produced its `.build/go/*.ELF` fixture. The first
build takes several minutes (one `make.bash` pass; the cross-std pass is
phase-2 opt-in via `GOVIRELAI_STD=1`); every Go release
rebase re-runs `apply.sh` on a fresh distribution copy. Auto-building the
fork inside the gate was considered and rejected — a multi-minute external
toolchain build inside every fleet run hides gate latency and couples the
fleet to the host's Go install.

The fork lives OUTSIDE the repo (`../go-virelai` by default; `--fork-dir`
or `GO_FORK_DIR` to move it) — it is a build artifact; this directory is
the reviewable patch series. `GOTOOLCHAIN=local` is exported by
`build-go.sh` so cmd/go can never silently swap back to a stock toolchain.

### Fresh sbrk alignment padding

Step 3d also applies an exact, idempotent edit to `runtime/mem_sbrk.go`.
Only `GOOS=virelai`'s successful `sbrk` branch of
`sysReserveAlignedSbrk` calls `memFreeWithClear(r, l, false)`. It links
already-zero padding with the existing free-list algorithm, writing only
`memHdr` records, not sweeping the 64 MiB alignment gap. Plan9/wasm still
call `memFree(r, l)`; ordinary frees and both free-list alignment trims
still clear. Unknown or partially edited source refuses provisioning.

The zero invariant is over bytes, not just newly mapped pages:

- `virMmap` requests anonymous RW memory without POPULATE. The kernel's
  demand-fault path zeroes each physical page before installing its leaf.
- Retained `[bloc, blocMax)` bytes were cleared by `sysFreeOS` **before**
  lowering `bloc`. Growth reuses those bytes without skipping that clear.
- `initBloc` rounds past the ELF end. `initBlocFloor` rounds past the
  complete argv/envp block. Neither the ELF tail nor the block's page slack
  enters this interval: the loader does not promise zero slack.
  Successful mmap also excludes the protected image/argv apertures.
- `memlock` serializes break/free-list changes. Live allocations and
  free-list headers lie below the old break. `memAllocNoGrow` clears the
  header it removes, preserving zero-filled allocations after reuse,
  splitting and coalescing.

No arena-size, alignment, `sysUnusedOS`, ABI, cap or budget changes follow
from this edit. The engine ledgers remain source audits; kernel receipts,
not this invariant or MemStats, establish physical-memory use.

## Daily loop (M69e, issue #1532)

Everything above is a build manual. This is the product loop it serves, and it
has three steps — **the middle one is not the guest's**:

1. **Edit.** In GOSH, or in NOTE/GOEDIT, write a `.go` file into `/host` (the
   share). From a boot script the monitor's own verb does it:
   `write LOOP.GO 'package main; func main() { println("hi") }'` — it joins its
   arguments, appends no newline, and reports the bytes it persisted.
2. **Compile — on the Mac.** `bash tools/go/build-go.sh <program.go>` (or
   `just go-toolchain` for the pinned fixtures), then the ELF is in the share.
   The guest did not compile it, and nothing may suggest it did.
3. **Run.** `exec LOOP.ELF` on the guest console, or the same line inside GOSH.
   The image is read out of the share at load time.

`go-hello` runs 09-10 are this loop as a class-B gate, and they sequence it:
run 09 has the guest author `/host/LOOP.GO`, the spec's python hook on run 09
builds **that file** on the Mac (asserts are evaluated between runs, so the
compile really does sit after the edit and before the run), and run 10 executes
the image the Mac built from the guest's own bytes. The host prints
`loop: host-built GOOS=virelai LOOP.ELF …` into the gate log; the hook refuses
when `$GO_FORK_DIR/bin/go` is missing, so no `make.bash` runs inside a gate.
Both runs assert that receipt absent from the guest's serial, which is how D1
("the compiler is the Mac") is pinned rather than promised.

**What is still not the loop**: a guest-driven `go build`. M70c S1/S2 landed
(#1543/#1544): the guest's own `cmd/compile` and `cmd/link` build and link
`tools/go/hello.go` (`go-hello` runs 06-08, `live-selfhost-go`), but their
inputs — the import config, the package archives and the staged/denied
package table — are staged by the host into the share
(`tools/go/stage-selfhost.sh` driven by the `tools/go/pkg-table.txt` policy,
M107b #2319), and a `go` command driving that
from inside the guest is a later card (ADR 0035 amendment 9).

## Phase map (issue #1163 / #1194)

- **0a**: single-thread, no sysmon (one `proc.go` delta), sbrk memory, no
  signals, cooperative preemption only. Kernel side: 3-segment gap-layout
  ELF loader, mmap cap lifts, `sys_getrandom` (slot 72, M51 #1166), FPEN
  armed. Landed #1187/#1196.
- **0b (this round, #1214)**: kernel slots 73/74 (`sys_thread`/`sys_futex`,
  ADR 0027) — **every `proc.go` delta is retired** (`patch_proc.py` is
  deleted; proc.go is byte-identical to upstream), newosproc maps Ms onto
  same-process kernel tasks, lock_sema parks on the futex,
  `numCPUStartup = 2`, exec argv on the gap path. The gate is
  `go-goroutines` (N=8 goroutines > GOMAXPROCS=2, `sys_thread` calls >= 2,
  the cross-core `task=GOROUT.ELF` smp proof). Round 2 also root-caused the
  go-args boot flake: the sbrk heap reservation (~1.2 GiB) swallowed the old
  ASLR stack band — the band moved to [0x1_0000_0000, 0x2_0000_0000) and
  `sys_mmap` now refuses collisions with the caller's own apertures
  (ADR 0007 amendment).
- **0b remaining**: none — envp half landed (#1226): gap-path `KEY=VALUE`
  block after argv, `goenvs` fills `envs`, `set GOMAXPROCS=N` overrides
  the default. `numCPUStartup` stays **2** (ADR 0027 D6; two vCPUs).
  Breadth stress (#1227): `go-stress` (GC churn, channel fan-out, timer
  pacing, futex contention at N=32).
- **0c**: landed (#1228) — kernel fault-delivery seam (slot 75
  `sys_exnotify`, ADR 0007 amendment) in the Fuchsia-exception-channel
  pattern, synchronous form: deliverable EL0 faults redirect to
  `sigtramp`, `virfaulthandler` arms `sigpanic` on the faulting stack
  (recover() works, the unwinder crosses the injected frame — proven by
  `go-panic`), `crash()` exits through the syscall instead of faulting.
  Async preemption stays OFF (no signals, only synchronous delivery).
- **2**: `syscall`/`os` packages over the file channel; real netpoll over
  ADR 0009 events (landed #1350).
- **2.1**: user-space clock (`vsys.Nanotime` reads CNTPCT_EL0) so `Conn`
  deadlines are wall-clock instants instead of scheduler-tick budgets;
  `Write` reports `ErrShortWrite` on truncation (claim #1358).

## Releasing upstream (someday)

Watch golang/go#73608 (`GOOSPKG`/`runtime/goos` overlay): if accepted, this
fork collapses into an overlay package (TamaGo's repo shows the migration
shape). Until then, rebase the fork each Go release (Aug/Feb cadence) —
expect a few hours per release; conflicts concentrate in `runtime/proc.go`
and `internal/platform/zosarch.go`.
