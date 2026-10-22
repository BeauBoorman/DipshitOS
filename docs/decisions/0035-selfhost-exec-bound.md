# ADR 0035: self-hosting M70c — what the guest can actually exec

- Status: ACCEPTED
- Date: 2026-09-19
- Issue: #1455 (M70c — this measurement is its first deliverable) · milestone
  #1437 (M70) · split card **#1504** (M70c-K)
- Related: ADR 0007 (syscall ABI — unchanged), ADR 0013 D3.1 (kernel .bss
  budget), ADR 0026 (Go runtime port — D6, the loader's accepted shape),
  ADR 0030 (Go is EL0), `docs/line-of-sight.md` (the Z0.5–Z4 ladder),
  #1434 (M66 — durable multi-MB staging, still open)

> **Superseded in part by Amendment 2 (below):** the kernel capability this
> verdict names landed as #1504, and S1/S2 are now blocked on a Go-side port
> (`syscall`/`os` for `GOOS=virelai`, card #1525). The measurement below —
> "the verdict does not depend on it" — still stands.
>
> **The verdict, up front: M70c's S1/S2 are blocked on a kernel capability,
> not on the Go side.** The guest stages every program through a fixed 2 MiB
> whole-file buffer, and the host's own `cmd/compile` carries 20.66 MB of code
> and read-only data alone. This ADR is docs-only: no code, no syscall, no
> kernel change, no boot-default move. It records the measurement the card
> asked for first, freezes its decisions, and carries the card split —
> **#1504** (the enabling kernel work) and **S3** (the reachable half).

## Context

M70c (#1455) wants the in-guest system to stop depending on the host
toolchain for the code it runs. S1 makes `GOVIRELAI_STD=1` the normal path and
has "the guest compile and link the pinned hello fixture **with the in-guest
toolchain**"; S2 is the in-guest build loop (a driver invoking `compile` then
`link`, no host `go build` in the loop); S3 is the Zig dialect capstone.

The card's enabling fact is real: `cmd/compile`, `cmd/link` and `cmd/asm` are
ordinary Go programs, and the fork already carries the machinery to produce
`GOOS=virelai` binaries. What had never been measured is whether the **guest**
can run programs that size. The card says so itself — "this is as much a
staging problem as a compiler one … measure the honest transfer and `mmap`
story first and record it". This is that measurement.

## Measurement (observed)

Each row is read off the current tree or measured on this machine; the
re-measure commands are at the end.

| bound | value | where |
| --- | --- | --- |
| exec staging | **2 MiB fixed whole-file buffer**, and there are **two** of them — `program` and `interp_program` (the PT_INTERP/LD.SO path), **4 MiB of .bss** — plus the 16 KiB header window the streamed path adds; the *staged* shapes (DSK1/DSK3/contiguous ELF/PT_INTERP) are still bounded by that buffer. Since K1 the gap-layout ELF path **streams** and is bounded instead by `exec_image_max` = 32 MiB (see the amendment) | `kernel/src/exec.zig` (`exec_program_max`, `exec_image_max`, `header_window`), `parse_dsk3` `image_size > buf.len` |
| ELF bounds | **two, since M72a (#1579)**: `load_max` = **32 MiB of INITIALIZED bytes** (`Σ p_filesz`, what comes off the volume) and `map_max` = **64 MiB of MAPPED bytes** (`Σ p_memsz` — a RAM budget when this was written; a VIRTUAL bound since card #3032, see Amendment 12). K1 raised the single 32 MiB total from 2 MiB; the split exists because zero-initialized `.bss`/`.noptrbss` costs no file bytes, so charging it against a bound named for the file refused images the file could not even hold. ≤3 PT_LOADs | `kernel/src/elf.zig` (`load_max`, `map_max`, `max_segments`) |
| GOOS=virelai link recipe | text base 0x10000 with its end ≤0x80000 (**448 KiB** of text), rodata base 0x80000 with its end ≤0x110000, data base 0x110000 | `tools/go/build-go.sh`'s layout guard (the guard exists because a shifted layout "loads but misbehaves on target") |
| gap vaddr bound | every gap segment's vaddr below `gap_base_max` = 0x1000_0000 | `kernel/src/elf.zig:158` |
| page tables | fixed **512×4 KiB (2 MiB) .bss carve-out, never reclaimed** — a *total-roots* budget | `kernel/src/mmu.zig:66-71`; `tables_used()`/`tables_capacity()` at `:146` |
| kernel .bss budget | 11,534,336 B (11.0 MiB) | ADR 0013 D3.1, `tools/verify-bss-budget.sh` |
| guest RAM | **256 MiB** | `host/vm-runner/Sources/VMRunner/main.swift:1347` |
| host `cmd/compile` | **27,061,906 B**, of which `__TEXT` (code+rodata) **20,660,224 B**; `strip -x` → 25,233,584 B (−6.8%) | measured 2026-09-19, Go 1.27.1, darwin/arm64 |
| host `cmd/link` | 6,878,850 B — `__TEXT` 5,423,104 B; `strip -x` → 6,503,808 B | same |
| host `cmd/asm` | 5,341,682 B | same |
| largest in-guest Go program today | `GOBIG.ELF` at **9,502,880 B** (the K1 fixture — 8,416,224 B of it one initialized `.data` payload); before K1 the largest was `GOSH.ELF` at 1,376,416 B, 66% of the old file bound | `.build/go/` |
| file-channel transfer | 32 KiB reply cap, **stateless offset-carrying READ**, paths ≤255 B | `docs/host-file-channel-scoping.md` |

### What is observed and what is inferred

- **Observed:** every bound in the table, and the host tool binaries' sizes.
- **Inferred (labelled, not asserted):** the exact size of a `GOOS=virelai`
  `cmd/compile`. A cross-std build (`GOVIRELAI_STD=1` — the fork at
  `../go-virelai` has no `pkg/virelai_arm64` yet) would produce it. **The
  verdict does not depend on it:** a GOOS swap exchanges the runtime/OS layer,
  which is a small fraction of `cmd/compile`; the *floor* is already
  `__TEXT` minus the darwin-only code, i.e. ~20 MB, against a 2 MiB bound.
  Nobody should read "we have not built it" as "it might fit".
- **Unmeasured (named, not guessed):** in-guest transfer throughput, and
  `compile`+`link` peak RSS in-guest. Both are acceptance criteria on #1504,
  not assumptions here.

## Verdict

**S1 and S2 are blocked. The precise blocked step:** the guest cannot `exec`
a program larger than `exec_program_max` (2 MiB), the loader stages the whole
file through a static array of exactly that size (two of them, in fact —
`program` plus the interpreter's `interp_program`, so 4 MiB of .bss is spent
on staging before any image is read), and `cmd/compile` is more than an order
of magnitude larger than the bound *before* stripping. Running
the toolchain in-guest therefore needs a capability that does not exist today:
**a streamed, per-process-aperture exec path** that does not copy the whole
image through fixed storage, plus page tables that are not drawn from a fixed
2 MiB carve-out. That is kernel work, and it is filed as **#1504 (M70c-K)**.

Two facts that keep this from being a dead end:

- **Staging is not the hard part.** The file channel already reads
  statelessly at an explicit offset with 32 KiB replies, so a 27 MB payload is
  ~845 reads and never has to exist in guest RAM as one buffer — *if* the
  loader streams. It is the exec seam, not the transfer, that forbids it.
- **The output half already fits.** A stripped in-guest-built hello is in the
  same size class as the existing fixtures (GOHELLO.ELF is 1.06 MiB of file /
  1.21 MiB of PT_LOAD memory), so once a large *toolchain* can run, the
  binary it produces is buildable today. The blocker is one-directional.

**S3 is not blocked.** `user/src/zc.zig` (3,910 lines) already compiles the
in-guest Zig dialect and `live-zc` runs its output on-machine — that is the
self-hosting capability that exists, and the Z4b step is described in
`docs/line-of-sight.md` as "explicitly a negotiation, not assumed", to be read
before promising anything.

## Decisions

**D1. No new compiler.** Unchanged from the card: this arc cross-compiles
upstream `cmd/*` for `GOOS=virelai`; writing a Go compiler is not on the
table.

**D2. Offline inputs only.** Unchanged: no `GOPROXY`, no module fetch, no
`net/http`; vendored or pinned inputs from the host share.

**D3. The guest stays the guest.** Unchanged: the in-guest build produces
`GOOS=virelai` guest programs, never host binaries.

**D4. Staging remains a host dependency, and so does the payload's size.**
The card already required stating which part stays host-provided; this ADR
extends it: *today the host also decides whether the toolchain can run at
all*, because the guest's exec seam cannot hold it. Nobody may read S1 as
"self-hosted" while that is true.

**D5. The enabling work is a kernel card, not a tools change (#1504).** No
build flag, linker recipe, `-ldflags`, or "smaller compile" trick closes a
10× gap in code size. The load path gains a streamed, non-fixed-aperture form
whose bounds are visible and whose refusals are named.

**D6. The bar for S1 stays behavioral.** "The in-guest-built binary runs and
prints the pinned line" — byte-equality with the host-built binary is not the
bar (build IDs and paths differ), exactly as the card already said. Add to
that: **a peak-RSS figure in-guest**, because "it builds" in a 256 MiB guest
is otherwise unfalsifiable.

**D7. Page-gate hygiene.** #1504 changes the exact-count page and page-table
gates' inputs. Those gates get **re-derived and amended with their own
measurement** — never loosened so that a large image can pass.

## Card split

| piece | card | acceptance | state |
| --- | --- | --- | --- |
| streamed exec + per-process text aperture + the RAM floor | **#1504** (M70c-K) | a >8 MiB stripped Go ELF execs in-guest and prints its pinned marker; oversized and truncated images still refuse by name; .bss gate green (or ADR 0013 amended with the observed number) | **filed, unclaimed — the blocker** |
| S1/S2 (toolchain in-guest, in-guest build loop) | #1455 | behavioral: the in-guest-built binary runs; peak RSS recorded | **blocked on #1504 and #1434** |
| S3 (Zig dialect capstone) | #1455, riding `live-zc` | whatever the Z4 ladder notes support, landed as its own shard or recorded precisely | **reachable now** |
| multi-MB durable staging | #1434 (M66) | already its own card | **open — dependency of #1504** |

## Non-goals

No dynamic linking beyond what #1504's mapping work needs; no new syscall
without an ADR 0007 amendment; no .bss budget change without amending ADR
0013 D3.1 with the observed post-change measurement; no change to the
GOOS=virelai code shape or the boot default; no in-guest `go test`, no module
resolution, no self-hosting the kernel, no replacing `zc`, no `cgo`; and no
attempt at S1/S2 code until #1504 lands.

## Amendment — K1 (M70c-K, #1504)

This amendment is part of the change that lands K1; it records what changes
and what is still open. The decision text above is history and stays as
written (its card-split table is the pre-landing state: since then S3 landed
as PR #1511 and #1504 was claimed). K2 — the aperture bound — is the same
change: `elf.load_max` moved with the loader. K3 is not; see below.

**What the loader does now.** The gap-layout static ELF path — every
`GOOS=virelai` Go binary — no longer stages the file. The loader reads a
16 KiB header window, parses the plan from it (`elf.parse_head` validates
segment *payload* ranges against the file's STAT size instead of a buffer),
then streams each segment straight from the host share into the physical
pages that will be mapped. Every other shape (DSK1, DSK3, the contiguous ELF
layout, PT_INTERP) keeps the staged path exactly — same one-read behaviour,
same `exec_program_max` bound. One pre-existing hole closed on the way: a
*contiguous* three-segment image used to reach the staging copy that only
represents `[text][data]`, i.e. it loaded with its rodata and data silently
missing; it is now refused.

**The refusals name the bound, not "too large".** One old name,
`ExecResult.too_large`, covered three different truths — and the monitor
printed one buffer bound for all of them, so a reader could not tell which
limit an image had crossed. It is now three:

| result | means | monitor line |
| --- | --- | --- |
| `image_too_large` | the FILE is past `exec_image_max` (32 MiB), whatever its shape | `error: <name>: image too large (acceptance bound 0x0000000002000000 bytes)` |
| `staging_too_large` | the shape must transit the 2 MiB staging buffer (DSK1, DSK3, contiguous ELF, PT_INTERP) and does not fit | `error: <name>: image too large for the 0x0000000000200000-byte staging buffer (only a gap-layout static ELF streams past it)` |
| `image_truncated` | the file ends before the bytes its own header promises | `error: <name>: truncated image (file ends before the bytes its header promises)` |

The truncation condition has **two detections and one name**, deliberately:
the header-window parse refuses a segment whose payload range escapes the
volume's STAT size (`elf.file_too_short`), and — if the file changes between
that parse and the load — the streamed segment read hits EOF. Which check
noticed is not the caller's problem; the DSK3 path reports it the same way
(a declared image that never arrived is `image_truncated`). No path ever
maps a half-filled segment.

**Observed acceptance (VZ, class B).** `go-hello` run 02 execs
`GOBIG.ELF` — a real stripped `GOOS=virelai` Go image of 9,502,880 B whose
last segment carries 8,416,224 B of initialized data — and the program
prints a banner it reads back at runtime from 1, 4 and 8 MiB into that
payload (`A B C E D`, `big: sum 335`), with the kernel reporting
`datapages=2097`. Run 01 (the 1.19 MiB `GOHELLO.ELF`, staged) is unchanged
and still green. Run 03 execs two real fixtures made from that image —
`XL.ELF` (34 MiB, past the acceptance bound) and `TRUNC.ELF` (its first
4 MiB, laid out so its data segment is cut off) — and asserts each refusal
by its own message, in order, with neither reporting a successful load.

**Both new run shapes were shown able to fail.** Aiming the streamed read
4096 bytes past each segment's own file offset (a one-line mutation): run
02 **FAILs** on `big: banner A B C E D` (and the load marker stays green —
the banner is what catches a read that succeeds against the wrong bytes),
while run 01 and run 03 stay green. Replacing the acceptance bound with the
staging bound in the size refusal (a one-line mutation): run 03 **FAILs**
by name, `XL.ELF: image too large (acceptance bound` = 0 and
`serial-absent 'staging buffer'` = 0, while run 01/02 stay green. Both
reverted; the gate then reports 3/3 again. Host tests cover the same path
with the channel's real 32 KiB reply bound pinned (`read_chunk`'s test
override now clamps like the wire does).

**K3 is not satisfiable yet, and not because of this card.** It measures
`compile`+`link` peak RSS *in-guest*, which needs the toolchain to run
in-guest — i.e. S1/S2 themselves. The host-side figures in the table remain
the best available upper bound, and the RSS figure stays an acceptance
criterion on #1455's S1/S2, not on #1504.

**D7 (page-gate hygiene).** K1 does not change how many pages any existing
shape takes: the streamed path maps exactly the declared segments, the
staged path is untouched, and the acceptance run reports the fixture's own
page counts (`datapages=2097`; the host test pins the exact delta,
1 + 768 + 2 + 1 + 48 + 48). The loader/exec regression set is green *on this
change*: `live-elf`, `live-exec`, `live-el0-exec`, `live-m16-image`,
`live-scale`, `live-oliver` (7/7) and `go-hello` (3/3).

Five further gates D7 names are **red on the base commit already**, for
reasons this change does not touch. Each was re-run at `81ebaa9d` with the
work stashed (`dirty-files=0`) and then on this change; each fails
identically both times, which is the evidence — the short cause notes below
are context, not a diagnosis this card owes:

| gate | observed failure (same at base and on this change) | note |
| --- | --- | --- |
| `live-long-lived` | `FAIL: running rows absent` | its `procs: id=… state=running` regex predates the `uid=`/`caps=` columns |
| `live-m16-resources` | `expected 8 running COUNTER rows, got 0` | same regex, same columns |
| `live-kill` | `page recovery off first=61844 second=61941` | a pinned `+17`-page recovery that predates the 192 KiB task stack (observed `97` = 1 text + 48 stack + 48 kernel stack) |
| `live-m16-guards` | `procs GUARD.BIN exited status=1` where the spec wants `139` | `GUARD.BIN`'s 36 KiB step predates the same stack growth, so it exits through its own closed-guard-gap branch instead of faulting |
| `live-m16-composition` | `missing GLOBALS.BIN exited status 42`, `serial-count [exec: loaded USER.BIN size=]=0 (min 7)` | its scripted composition stops before its later phases |

None of the five is re-derived or loosened here, and none may be: a large
image is not going to be made to pass by relaxing a page or row gate. They
are answered as one card instead — **#1522** (re-derive or retire, with the
measurement in its own PR).

**`.bss` gate:** green, `12,020,408 B / 13,631,488 B` (1,611,080 B
headroom) with the 16 KiB header window in place; the two 2 MiB staging
arrays stay, because the staged shapes still need them. ADR 0013 D3.1 is
unchanged.

## Amendment 2 — M70c (#1455): the exec blocker is retired, the port layer is the blocker

#1504 landed (PR #1523, merge `1e757d15`): the gap-layout path streams, its
acceptance bound is 32 MiB, and a 9.5 MiB `GOOS=virelai` image execs on VZ. The
"precise blocked step" named in the verdict above — *the guest cannot `exec` a
program larger than `exec_program_max`* — is **closed**. This amendment records
the two things the card's S1/S2 still wait on: the step that blocks them now,
and the transfer measurement the card asked for first and never got.

### The new blocked step: there is no `syscall`/`os` port for `GOOS=virelai`

Observed on the fork (Go 1.27.1, `GOROOT=../go-virelai`):

```
$ GOOS=virelai GOARCH=arm64 go build -o /dev/null fmt
# syscall
../go-virelai/src/syscall/syscall.go:50:15: undefined: EINVAL
../go-virelai/src/syscall/syscall.go:80:11: undefined: Timespec
../go-virelai/src/syscall/syscall.go:85:11: undefined: Timeval
# internal/poll
../go-virelai/src/internal/poll/fd_mutex.go:212:11: undefined: FD
```

`fmt` is the smallest interesting target; `os`, `path/filepath`, `go/ast` and
every `cmd/*` package sit behind the same two. The fork's virelai-tagged files
are **runtime only** — `runtime/{os,signal,netpoll}_virelai.go`,
`runtime/{sys,rt0}_virelai_arm64.s`, `internal/goos/zgoos_virelai.go`, plus the
`mem_sbrk`/`lock_sema`/`stubs*` tag lists — and `src/syscall`/`src/os` carry
nothing for this GOOS. Three consequences, and the first two are sharper than
the original verdict:

- **`GOVIRELAI_STD=1` cannot build.** S1's "cross-std on by default" half is
  not a flag flip: a full `GOOS=virelai make.bash` starts by compiling
  `syscall` for a GOOS with no `syscall` type/const surface. The re-measure
  command in the section below (`GOVIRELAI_STD=1 bash tools/go/build-go.sh`)
  fails one package in.
- **No toolchain binary for `GOOS=virelai` can be produced today at all** —
  not "it builds but cannot run", which is what the original verdict
  described. So the `cmd/compile`-size row above stays an **inference** (a
  GOOS swap exchanges the runtime/OS layer, a small fraction of the binary),
  and the size gate S1 needs cannot be closed by building it.
- **The fix is a port, not a knob.** `build-go.sh` already names its shape
  ("the syscall/os port layer (the wasip1 mirror)"):
  `syscall/syscall_wasip1.go`, `fs_wasip1.go`, `net_wasip1.go`,
  `internal/poll/fd_wasip1.go` and the `os` glue — hand-written file-ABI
  plumbing, which here means ADR 0010's file surface over the ADR 0007 slots
  the kernel already serves. Filed as its own card, **#1525** (M70c-S1P);
  S1/S2 wait on it.

**D4 stands, for a new reason.** The toolchain payload stays host-produced.
The old reason (the guest's exec seam cannot hold it) is retired; the current
one is that the guest cannot yet compile the toolchain's own source for itself.

### Amendment 3 — M70c-S1P (#1525): the ported `syscall`/`os` build, and the link windows become the next wall

Observed on the fork, same toolchain, after the port landed
(`tools/go/overlay/{syscall,internal/syscall/unix,internal/poll,time,os}`):

```
$ GOOS=virelai GOARCH=arm64 go build fmt      # exit 0 — no output
$ GOOS=virelai GOARCH=arm64 go build os       # exit 0
```

That is the S1/S2 prerequisite the section above names, so `fmt` — and with it
`os`, `path/filepath`, `go/ast` — now **compiles** for this GOOS. What the
guest runs is a different claim, and the card's fixture (`tools/go/gosyscall.go`)
settles it the hard way: it **builds, links, loads and starts** —
`exec: loaded GOSYSCALL.ELF size=0x98194 … datapages=51` — and then dies in
`runtime.mallocinit`:

```
fatal error: runtime: cannot allocate memory
runtime.throw({0xb4404?, 0x0?})
	runtime/panic.go:1243
runtime.persistentalloc1(0x100, 0x0?, 0x1b01c0)
	runtime/malloc.go:2363
… runtime.mheap.init → runtime.mallocinit → runtime.rt0_go
```

Why, and this is the finding that outlives the card: **any image that imports
`os` no longer fits the link recipe's windows.** Measured
(`tools/go/build-go.sh`'s guard, `tools/go/gosyscall.go` with `os` only, no
`fmt`):

```
text ends 0x92fc4 > 0x80000; rodata base 0xa0000 != 0x80000;
rodata ends 0x149558 > 0x110000; data base 0x150000 != 0x110000
```

448 KiB of text was a runtime-only budget. The Go linker then shifts the later
segments, the kernel faithfully maps them at their declared vaddrs (#1504's
gap streaming) — and the runtime's sbrk heap starts at
`memRound(firstmoduledata.end)`, which for the shifted layout is page-rounded
into the **loaded data aperture**, so the kernel's `mmap_collides` check
(system 1214's rule: a mapping may never alias a region the process owns)
refuses the process's first heap mapping. The unshifted images did not hit this
by geometry, not by design: their data aperture ends exactly where the linked
`end` rounds to.

Consequences, stated as constraints rather than guesses:

- **The recipe's apertures, not the port, are now the gate**, filed as **#1540**
  (M70c-S1L). Widening them (explicit link bases) or making the break's base
  page-safe relative to the loader's aperture end is that card's work. Until it
  lands, no in-guest fixture that imports `os` can pass, which is why
  `go-hello` had no std-fixture run at this point — **amendment 4 has both the
  resolution and the correction to the diagnosis below**.
- **`cmd/compile` is ~40x past the text window** (448 KiB here vs 27 MB of
  host `cmd/compile`), so this wall has to come down for S1/S2 regardless of
  which std packages they link.
- **Link-time gaps are invisible to `go build`.** The port's first link failure
  was `os.(*File).Write: relocation target os.sigpipe not defined` — the
  virelai runtime's `os_sigpipe` had never carried its `//go:linkname`, and no
  earlier fixture used `os`, so nothing had ever referenced the symbol. Fixed
  in the same card; the general lesson is that "`go build fmt` succeeds" is a
  **compile-time** claim and must not be read as "a guest program using `fmt`
  runs".

### The transfer half, measured

The card's other half — "measure the honest transfer and `mmap` story" — now
has both numbers. The `mmap` half is K1's (`datapages=2097` for an 8.4 MiB
payload, run 02). The transfer half is `go-hello` **run 04**: `GOREAD.ELF`
reads a 9.5 MiB `GOOS=virelai` image back out of the host share end to end with
nothing staged in between, and the host recomputes both the byte count and the
FNV-1a hash of the bytes the guest actually read.

| transfer, observed on VZ (2 vCPU, 256 MiB) | value |
| --- | --- |
| EL0 read cap | **2048 B per `sys_file_read`** (`kernel/src/syscall.zig`: `@min(count, 2048)`), against a **32 KiB** wire reply cap (`virtio_file.reply_cap`) — so a payload is served in ~15× more calls than the wire would allow |
| payload read | **9,502,880 B in 4,641 calls**, largest single call **2048** — exactly `ceil(bytes/2048)`, i.e. every call moved a full chunk (run 2: identical) |
| elapsed | **298,379 µs** (run 2: **311,010 µs**) |
| goodput | **31,101 KiB/s** (run 2: 29,838) ≈ **30 MB/s**, **~15,300 calls/s** |
| per call | **64,292 ns** (run 2: 67,013) — one virtio round trip; the guest-side fold is under 4 % of it |
| hash | FNV-1a 64 of the bytes READ = the same file hashed on macOS (`0x7085f0327a474278`) |

**What it means for S1/S2 — arithmetic, labelled as extrapolation:** a
27,061,906 B `cmd/compile` is ~13,200 calls at this cap ≈ **0.85 s** of channel
time (`27,061,906 × 298,379 / 9,502,880` µs; this measures the rate, not that
file). Writes are capped identically (2048 B per `sys_file_write`), so a few MB
of object output is ~0.2 s. **Transfer is not the blocker.** At the ABI's own
cap a toolchain-scale payload costs well under a second per pass, and the
whole-file-buffer shape the old verdict worried about is not needed to read one
— bounded memory and the existing offset-carrying READ are enough.

A widened cap would show up as a changed call count in run 04, which is
asserted: the run's exact line (`bytes <n> calls <ceil(n/2048)> max 2048`) is a
deliberate tripwire, because these numbers are what S1's cost estimate rests
on. Both halves of that assert were shown able to fail before landing — a
fixture that counts a chunk without folding it fails the hash half with the
byte/call line still exact; one that stops 1 MiB short fails the byte/call
half — with runs 01–03 green in both cases.

## Amendment 4 — M70c-S1L (#1540): the std fixture RUNS, and the wall was neither the port nor the linker

Observed on VZ, `go-hello` **run 05** (class B, `tools/go/gosyscall.go`):

```
exec: loaded GOSYSCALL.ELF size=0x98644 entry=0x807e0 datapages=51
gosyscall: os mkdir ok
gosyscall: os write PAYLOAD.TXT bytes 32
gosyscall: os write SECOND.TXT bytes 24
gosyscall: os readback PAYLOAD.TXT ok bytes 32
gosyscall: read 2048
gosyscall: second read 1 byte 0
gosyscall: stat size 9502880 isdir false
gosyscall: fstat size 9502880
gosyscall: raw dirent bytes 80
gosyscall: absent no such file or directory
gosyscall: os bytes 9502880 hash 0x7eb82998
gosyscall: os stat size 9502880 isdir false
gosyscall: os stat PAYLOAD.TXT size 32 isdir false
gosyscall: os dir entries 2 files 2 dirs 0
gosyscall: os remove ok 2
gosyscall: os dir entries 0 files 0 dirs 0
gosyscall: GOSYSCALL OK
```

`0x7eb82998` is the host's own FNV-1a 32 of the staged 9.5 MiB image,
recomputed off the share (the 64-bit sum in run 04 is a different fold of the
same file). The host also checks from its side that the guest's `os.Mkdir`
landed in the share and that the two `os.Remove` calls really took the files
away. So "the standard library drives this kernel" is now observed bytes, not a
compile exit code. Negative controls, each run before landing: with the runtime
floor below removed the run dies in `mallocinit` with `cannot allocate memory`
(runs 01–04 still pass); with one byte dropped from the guest's fold the host's
hash assert fails while every other line still matches.

### What the wall actually was (amendment 3 was one step off)

Amendment 3 read the `mallocinit` death as "the shifted layout puts the sbrk base
inside the loaded data aperture". The aperture half is right; **the segment shift
is a coincidence, not the cause.** The two rules that collide are:

- the kernel reserves the writable segment's extra tail page for the packed
  argv+envp block and protects the data aperture *through that block*: the
  collision span is `max(pageRound(mem_size), align8(mem_size) + 2304)`
  (`process.zig mmap_collides`; `exec.zig` packs 8×32 + 16×128 = 2304 B there);
- the runtime starts its heap at `memRound(firstmoduledata.end)`, i.e. at
  `round_up(mem_size)` — which is INSIDE that span whenever the block reaches
  past the page-rounded image end: `mem_size mod 4096 > 4096 − 2304 = 1792`.

Runs 01–04 pass because their data segments leave `r = 688` and `r = 1072` of
slack; the std fixture has `r = 3280`. Measured across every `GOOS=virelai`
image built in this worktree, GOSYSCALL is the **only** one on the wrong side of
that boundary — every other has `r ≤ 1520`.

None of this was unknown: `user/go/sh/main.go` and `user/go/sshd/main.go` each
carry an `argvEnvpGuard` padding array for exactly this refusal ("adjust this
array's size when it trips"), and `tools/go/build-gosh.sh` asserts the same
boundary from the linked ELF (`slack ≥ 0x908`). So the mechanism was understood
and worked around **per program, by hand**. What #1540 changes is who owns the
rule: the runtime, once, instead of every new std program having to discover the
boundary and pad its bss to sit on the right side of it. The pads and that
assert stay — harmless, and they name the invariant if it ever regresses — but
they are no longer what keeps a Go program alive. That is the difference between
a 1792/4096 coin flip and a rule.

### The fix, on the runtime side

`initBlocFloor` (`overlay/runtime/os_virelai.go`) starts the break on the page
after the block the kernel packed, using the block VA the rt0 stub records
before it converts that block to rt0_go's SysV array. Raising the floor only
ever skips the block's own page — the only thing living there — so an image
whose slack already clears the block is byte-for-byte unchanged, which is why
runs 01–04 stayed green.

**Widening the recipe was not needed**, and that is a finding: the loader maps
each segment at its declared vaddr (#1504), so a shifted image is legal — only
the break base was unguarded. Explicit link bases remain useful for the S1/S2
40× text gap (`cmd/compile` vs the 448 KiB window) and are that card's business,
not this one's.

### Two port bugs the fixture caught that no earlier gate could

Amendment 3's own warning — "`go build fmt` is a compile-time claim" — came true
twice, and both bugs were in the **port**, not the kernel:

1. **The POSIX→kernel open-flag translation was wrong.** `kernelOpenFlags`
   passed the POSIX word through: a read-only open sends `O_RDONLY = 0`, which
   `file_table.open` refuses (`flags == 0`, and `MODE_READ` is `0x1`), while
   `O_CREAT = 0x40` is not a MODE bit at all. The port now keeps a separate
   MODE_* word (`kmodeRead`/`kmodeWrite`/`kmodeCreate`/`kmodeAppend`/`kmodeDir`)
   and translates; it failed closed with EINVAL, which is why it was visible
   immediately.
2. **`O_TRUNC` was implemented by calling the port's by-path `Truncate`, which
   is an honest `ENOSYS`** (slot 36 is handle-addressed) — so every
   `os.WriteFile` failed with ENOSYS. The kernel's write-open already truncates
   (replace semantics), so the call was both broken and unnecessary; removed,
   with the reason at the site.

Both survived #1525's review as "the thing to press on" and both are precisely
what the missing in-guest run would have caught — the case for run 05 existing.

### A found limit, named rather than papered over

`Stat` has no slot: the port answers from a row on the entry's PARENT. That
listing has **no cursor and the kernel clamps one call to 16 rows**, and this
gate's share (the seeded app bundle) holds ~30 entries — so
`os.Stat("/host/GOBIG.ELF")` returned ENOENT for a file that was right there.
The port now falls back to what the ABI can still say: listing the path itself
proves a directory, otherwise it opens the file and reads to EOF to learn its
size. Correct, and **O(size)** — stated in the port and here rather than hidden
(a `stat` verb, or a listing cursor, is a kernel-surface card, not this one).

### Still unmeasured, and why

**`compile`+`link` peak RSS in-guest** — unchanged from K3, and unmeasurable for
the same reason: it needs the toolchain to run in-guest, which needs S1/S2 to be
possible at all. It remains an acceptance criterion on #1455; the host-side
figures in the table above are still the best available upper bound. **Transfer
throughput is no longer unmeasured**, and the std layer is now *executed*, not
merely compiled.

### Card split, as it now stands

| piece | card | state |
| --- | --- | --- |
| streamed exec + per-process text aperture + the RAM floor | #1504 (M70c-K) | **landed** (PR #1523, `1e757d15`) |
| the `GOOS=virelai` `syscall`/`os` port | **#1525** (M70c-S1P) | **landed** (PR #1541) |
| the std fixture runs (`go-hello` run 05) | **#1540** (M70c-S1L) | **landed** (this amendment) |
| S1/S2 (toolchain in-guest, in-guest build loop) | #1455 | unblocked in principle: the std layer builds AND executes; the 40× text gap is the remaining structural work |
| S3 (Zig dialect capstone) | #1455, riding `live-zc` | **landed** (PR #1511) |
| multi-MB durable staging | #1434 (M66) | cards landed; index issue open |

## Re-measuring (so the next agent does not have to take this on faith)

```bash
# the guest walls
sed -n '95,110p;180,190p' kernel/src/exec.zig          # exec_program_max, the buffer
sed -n '158,203p' kernel/src/elf.zig                   # gap_base_max, load_max, map_max, max_segments
sed -n '64,72p;144,155p' kernel/src/mmu.zig            # the fixed table carve-out
bash tools/verify-bss-budget.sh                        # 11,534,336 B, observed value in the log
grep -n memorySize host/vm-runner/Sources/VMRunner/main.swift
grep -n -A4 'FIXED text aperture' tools/go/build-go.sh  # the 448 KiB recipe window

# the payload (host; Go 1.27.1)
size -m "$(go env GOROOT)/pkg/tool/$(go env GOOS)_$(go env GOARCH)/compile"
cp "$(go env GOROOT)/pkg/tool/darwin_arm64/compile" /tmp/c && strip -x /tmp/c && ls -l /tmp/c

# the exact GOOS=virelai figures (opt-in cross-std pass). Since #1525 the port
# exists and std closes except `net`/`net/internal/socktest` (no socket slots)
# and `internal/testenv` (test support wants a per-GOOS Sigquit) — run
# `GOOS=virelai go build std` to see the current list rather than trusting this
# comment.
GOVIRELAI_STD=1 bash tools/go/build-go.sh
cd "${GO_FORK_DIR:-../go-virelai}/src" && GOOS=virelai GOARCH=arm64 go build \
    -ldflags "-s -w" -o /tmp/compile-virelai cmd/compile && ls -l /tmp/compile-virelai

# the port layer, one package in (amendment 3+
# `apply.sh` installs it; both of these are rc=0 since #1525)
export GOROOT="${GO_FORK_DIR:-../go-virelai}"; export PATH="$GOROOT/bin:$PATH"
GOOS=virelai GOARCH=arm64 GOTOOLCHAIN=local go build -o /dev/null fmt
GOOS=virelai GOARCH=arm64 GOTOOLCHAIN=local go build -o /dev/null os

# the aperture arithmetic amendment 4 is about, per built image: the data
# segment's page slack (r <= 1792 clears the kernel's argv+envp block, and the
# runtime walks past it either way since #1540)
python3 - .build/go/GOSYSCALL.ELF <<'EOF'
import struct, sys
d = open(sys.argv[1], "rb").read()
phoff, phes, phnum = struct.unpack_from("<Q", d, 32)[0], struct.unpack_from("<H", d, 54)[0], struct.unpack_from("<H", d, 56)[0]
segs = [struct.unpack_from("<IIQQQQQQ", d, phoff + i * phes)[4:7] for i in range(phnum)]
last = [s for s in segs if struct.unpack_from("<I", d, phoff + segs.index(s) * phes)[0] == 1][-1]
print("data va=%#x mem_size=%#x slack=%d" % (last[0], last[1], last[1] % 4096))
EOF

# the transfer numbers (class B; run 04 of go-hello asserts the byte count,
# the call arithmetic and the hash, and prints the rate) and the std layer's
# run (run 05: the host recomputes the 32-bit hash and checks the share)
just gate go-hello
grep -a 'goread:' artifacts/go-hello-serial-04.log
grep -a 'gosyscall:' artifacts/go-hello-serial-05.log
```

## Amendment 5 — M70c-S1T (#1543): the acceptance bound, and a toolchain-scoped FIPS gate

Recorded late: #1543 was closed before its amendment was written, and the
measurement below is the whole reason that card existed, so it is kept here
rather than lost. Everything in this section is OBSERVED except where it says
otherwise; no VZ run was made, so no boot claim is made.

`cmd/compile` and `cmd/link` were made to LINK for GOOS=virelai by closing
three overlay gaps — the vendored x/telemetry `mmapFile`/`munmapFile` pair,
eight `syscall.recvfromInet4`-style linkname targets, and `syscall.Exec`.
Linking was not the wall. `elf.load_max` / `exec.exec_image_max` (32 MiB)
bounds the SUM of every PT_LOAD `memsz` (`elf.zig:548-552`, reached on the
streamed path via `exec.zig:447` -> `parse_head`), and the entire excess was
ONE symbol:

    33554432  crypto/internal/fips140/drbg.memory   (.noptrbss)

Measured, stripped (`-s -w`):

| image | sum of memsz | verdict |
|---|---|---|
| cmd/compile, default | 58,254,964 (55.56 MiB) | refused |
| cmd/link, default | 39,895,972 (38.05 MiB) | refused |

That buffer is demand-backed and free unless the FIPS module runs — upstream
says so in the file itself — so the bound was charging ADDRESS SPACE as
memory. The two GOOS-wide levers were tried and rejected: `GOEXPERIMENT=nofips140`
does not exist in Go 1.27.1 (`unknown GOEXPERIMENT fips140`), and `GOFIPS140`
already defaults to `off` (an explicit `off` build is byte-identical to the
default, md5 `39eb4f6becf69c447bd1f06c2d961655`). A GOOS-wide build-tag
exclusion would neutre `crypto/rand` for every guest binary and regress the
landed M47/M67 TLS work, so it was not taken either.

The shape taken instead: an opt-in `virelaitoolchain` tag, passed only when
building the two toolchain images, which excludes `drbg/entropy_fips140.go`
and selects a stub for `getEntropy`. Measured with the tag ON — cmd/compile
24,693,668 (23.55 MiB) and cmd/link 6,334,572 (6.04 MiB), both inside the
bound, and both passing EVERY `parse_impl` rule rather than just the bound.
With the tag OFF the numbers are unchanged to the byte, so apps keep the real
source and its buffer. `.noptrbss` falls 32.088 MiB -> 0.088 MiB and the
`drbg.memory` symbol disappears.

Two side findings, both measured, both worth keeping:

- A Go file's GOOS/GOARCH SUFFIX and its `//go:build` line are BOTH enforced.
  Upstream's `entropy_wasm.go` therefore cannot be reused for virelai: `_wasm`
  pins it to wasm whatever its build line says, and widening that line to
  include virelai compiled nothing and still reported `undefined: getEntropy`.
  The stub is a separate file because of this, not by preference.
- `cmd/link`'s writable segment is GEOMETRICALLY unfit to be exec'd with
  arguments: it left only 0x350 bytes of page slack, under the 0x908 the
  kernel's argv+envp block needs, so its first mmap was refused in
  mallocinit. Fixed by the same device `user/go/sh` uses — an
  `argvEnvpGuard` bss pad, added for this GOOS as an overlay file,
  `cmd/link/argvguard_virelai.go`. Measured after the pad: writable memsz
  0x69cb0 -> 0x6a690, slack 0x350 -> **0x970** (2416 >= 0x908).
  `cmd/compile` needed no pad (0x298668, slack 0x998 = 2456) but its margin is
  only 144 bytes, so the toolchain recipe ASSERTS the invariant for BOTH images
  rather than trusting a comment. Both images now pass every loader rule AND
  the slack rule.

Also recorded here: the linker emits segment 0 at 0x10000, not
`elf.text_base` (0x400000), and the loader accepts it — `parse_impl` sets
`gap_layout` when `raws[0].vaddr != expected_base` and maps every segment at
its declared vaddr. "Shifted-is-legal" needs no explicit `-T`/`-R` for a
GOOS=virelai binary. The module header at `elf.zig:14` still claims segment 0
MUST equal `text_base`; that line is stale against both the code and every
emitted binary.

## Amendment 6 — M70c-S2 (#1544): the in-guest build loop needs NO new spawn slot

Deliverable 0 of this card is a spike decided and RECORDED before any driver
code, choosing between (a) seat/sh-sequenced execs with `/host` handoff and
(b) a new ADR 0007 spawn slot. The answer is (a) — and the reason is that (b)
already exists, so nothing needs to be built to get it.

Observed in-tree: the guest has spawn-and-wait today. `sys_exec` (slot 28)
loads the named program from the share into a fresh process slot and spawns it
at EL0; `sys_wait` (slot 8) "blocks the caller until the target process exits
and returns its status — bounded, kernel-owned; NOT POSIX wait (no zombies, no
fds)". `user/go/vi` already wraps that pair as `vi.Exec(name, args...)`, and
the M68a Go shell uses exactly it: `user/go/sh/main.go:635` calls `vi.Exec`,
and `shell.go:825`'s `runExternal` "spawns name in the foreground and waits".
A guest-side driver can therefore sequence compile -> link with no kernel
change at all.

So NO ADR 0007 slot is filed for this card. The kernel split that this card
reserved is not needed — which is the strongest form of the rule the card set:
not smuggled, and not required.

What the chosen shape costs, named now rather than discovered later:

- `os/exec` stays ENOSYS by design, so `cmd/go` cannot drive the build. The
  driver is a guest program calling `vi.Exec` (compile, then link), which is
  what the card's "GOTOOLCHAIN=local offline driver" means — offline because
  nothing fetches a toolchain, not because a flag says so.
- No descriptor inheritance and no in-memory state between steps: every exec
  is a FRESH process, so intermediates (the .o, then the linked ELF) cross the
  steps as files on `/host`. That IS the handoff.
- argv is bounded (8 args, 31 chars + NUL each) and the concurrent user-slot
  pool is 4, reaped by the kernel. A bounded three-step loop fits; a general
  recursive build would not.
- (b) is rejected in full rather than deferred: a spawn slot plus a ported
  `os/exec` would buy descriptor inheritance and let `cmd/go` drive, which is
  the eventual shape for a genuinely self-hosting toolchain — but that is a
  kernel ABI change made to satisfy a three-step loop the existing pair
  already covers.

Dependencies for the driver, stated so the next agent does not have to
rediscover them: the toolchain-scoped FIPS gate (so the images clear
`load_max`) and the `cmd/link` argv+envp pad. Both are amendment 5, and both
were cleared on the #1543 branch before this spike was written.

## Amendment 7 — M70c-S1T (#1543): the guest builds its own hello, and the wall moved to the file position

Amendment 5 recorded the measurements that made the toolchain LINK; it made
no boot claim (no VZ run had been made). This amendment is the boot evidence.
All of it is OBSERVED on VZ through `tools/gate/specs/go-hello.spec` runs
06-08 (class B), each run one `exec` because the monitor's `exec` returns
immediately and the share carries the intermediate.

**D3 — the images exec with arguments.** `-V=full` is the assertion because
its output is the binary's own `argv[0]` plus the toolchain version, so the
line cannot appear unless the image loaded, ran at EL0, and had an argument
vector delivered: `GOCMDCOMPILE.ELF version go1.27.1` and
`GOCMDLINK.ELF version go1.27.1`, both with `procs <name> exited status=0`.

**D4 — the guest builds the pinned hello with its own toolchain.**

- Run 06, in-guest compile: `HELLO.o` (7,248 bytes) appears in the share, an
  ar archive whose header line reads
  `go object virelai arm64 go1.27.1 GOARM64=v8.0 X:regabiwrappers,regabiargs,`,
  holding `__.PKGDEF` and `_go_.o`. That header names the TARGET; a copied
  binary or a compile that silently did nothing cannot produce it.
- Run 07, in-guest link: `HELLO2.ELF` (1,684,249 bytes, 3 PT_LOAD,
  sum memsz 1,224,708 = 0x12b004, writable page slack 0xf50). The host holds
  the product to EVERY rule `elf.zig`'s `parse_impl` enforces — segment count,
  the `load_max`/`map_max` sums, `gap_base_max`, page alignment, W^X order,
  entry-inside-segment-0 — plus the argv+envp slack, before run 08 may execute
  it. This is the first binary produced INSIDE the guest checked against the
  kernel's acceptance geometry.
- Run 08: that ELF runs and prints the fixture's own vocabulary —
  `hello from virelai`, `heap: wrote 1048576 bytes`, `gc: cycle completed`,
  `virelai-go OK` — with no exception and no `cannot allocate memory`.

**The wall this moved to, and it was not memory.** The first in-guest compile
exited status 1 with the guest's own words:

    compile: seeking in output [0, 1]: seek /host/GPKG_runtime.a: function not implemented

`cmd/internal/bio` seeks to read package archives (`Offset()`, then
`cmd/internal/archive`'s member offsets) and `cmd/compile/internal/gc/obj.go`
seeks on the object it is WRITING (it patches the archive header after the
members). The kernel has no seek, no pread and no pwrite: a handle is a cursor
(slots 23-27, 34-36, 77). So the port grew a positional layer
(`tools/go/overlay/syscall/fs_virelai.go`): a per-handle shadow of the bytes
moved from offset 0, the kernel cursor, and the caller's logical position.
Reads behind the cursor are served from the shadow; reads at it are fetched;
writes are STAGED and pushed at `Fsync`/`Close`, because a patch (seek back,
write, seek forward) cannot be applied to a device that only appends.
`Pread` is answered from the same shadow; `Pwrite` stays refused.

This was a port change, not a kernel change: no slot was added and no ABI
moved. The bounds are named rather than hidden: the shadow retains 16 MiB per
handle and a positional request it can no longer answer returns ENOSYS instead
of bytes from the wrong offset; a writer whose process dies without closing
loses what it staged. Both are outside what this toolchain does.

**D5 — the in-guest memory figure (this ADR's D6 question).** The kernel
exposes no peak-page ledger, so this is a SAMPLE, taken by typing the
monitor's `sysinfo` allocator line from a stage-gated script while the
process ran — not a peak:

| process | guest frames used (sampled) | vs the guest |
|---|---|---|
| in-guest `cmd/compile` | 8,372 of 65,215 (33,488 KiB of 260,860 KiB) | sampled twice, identical |
| in-guest `cmd/link` | 18,483 then 32,843 of 65,215 (73,932 then 131,372 KiB) | the larger of the two |

So a 256 MiB guest HOLDS this toolchain: the link is the heavier of the pair,
and it finished with 32,372 of the guest's 65,215 frames still free. The
caveats are the ones that matter for anyone re-measuring. First, these are
samples, not a peak: the compile's two samples are identical, so its footprint
had already returned by both, which BOUNDS the compile rather than peaking it,
and a true peak needs a kernel-side ledger that does not exist (named here as
the gap, not worked around). Second, samples move — the same runs in the
standalone trial peaked higher (the link's second sample was 38,611 frames,
154,444 KiB), which is what a sample taken at a different instant does.

**Two mechanical bounds, both measured, both needed a second look.** The
`cmd/link` argv+envp pad from amendment 5 had to be resized (0x9b0 -> 0x11b0)
because adding port code moves the bss: measured slack fell 0x970 -> 0x790 and
is 0xf90 with the new pad. `cmd/compile` needed a pad of its own (0x9b0;
slack 0xdd8) for the same reason, so BOTH images now carry one. The toolchain
build (`tools/go/build-gotool.sh`) asserts every loader rule and the slack
from the linked ELF, and `tools/go/stage-selfhost.sh` asserts the guest's argv
lines against the kernel's 8x32-byte budget, so neither failure mode costs a boot again.

## Amendment 8 — M70c-S2 (#1544): the build loop runs in the guest, and its third child does not

Amendment 7 proved the three steps work when the MONITOR drives them (go-hello
runs 06-08, one boot each) and amendment 6 chose the shape for driving them
from inside the guest. This is that driver, measured.

`tools/go/selfhost.go` (`GOSELFHOST.ELF`) runs the loop in ONE boot: it spawns
the guest's `cmd/compile`, waits, spawns the guest's `cmd/link`, waits, and
checks both statuses. Nothing fetches a toolchain — GOTOOLCHAIN=local is
literal for a guest with no `go` command — and every byte it reads is staged in
`/host` by `tools/go/stage-selfhost.sh`.

Observed, `tools/gate/specs/live-selfhost-go.spec` (class B, 2/2 runs):

| step | status | elapsed |
|---|---|---|
| `cmd/compile` (hello.go -> HELLO.o) | 0 | 2,000 ms |
| `cmd/link` (HELLO.o -> HELLO2.ELF) | 0 | 14,016 ms |

The link dominates because it reads 14.82 MiB of package archives out of the
share at the EL0 2048-byte read cap; the compile reads one archive's export
data. The products are the same ones amendment 7 measured (HELLO.o 7,248 bytes
with a `go object virelai arm64` header, HELLO2.ELF 1,684,249 bytes, 3 PT_LOAD,
sum memsz 1,224,708, slack 0xf50), checked on macOS against every loader rule,
and the gate's second boot executes the result and asserts its pinned lines.

**The wall, and a correction to it: a THIRD sequential exec from one EL0 parent
died once and has not died again.** The loop was written with three children —
compile, link, run the product — and the third died with the guest's own
tombstone:

    fault: HELLO2.ELF far=0x0000000047c29000 ec=0x24 pc=0x000000000007c528 esr=0x000000009200004f
    procs HELLO2.ELF exited status=139

The child was executing its own code (its entry is in the same text aperture as
the driver's) and took a level-3 permission fault on a data access at ~1.2 GiB,
one second in. This is the wall `go-sh.spec` already documents for Go children
— "A THIRD sequential exec from one EL0 parent currently dies in the Go
runtime's own schedinit (observed twice: refill of span with reusable pointers
-> fatal exit 2) ... follow-up owed to the runtime/kernel owners" (issue
#1449) — but with a DIFFERENT symptom, and this amendment claims only what it
saw: two independent observations, one wall, not yet a root cause.

What it costs the milestone: the loop is two children plus one monitor `exec`
for the product, so the build is guest-sequenced and the run is the gate's
second boot. A genuinely self-hosting toolchain still needs that third child to
survive (and then `os/exec`'s spawn-and-inherit story, so `cmd/go` can drive at
all). Both are named here rather than discovered by the next agent.

**The measurement that corrected the claim above.** PR #1552's review asked the
right question: BOTH known third-child deaths used a Go child (go-sh's children
are `GOSH.ELF`; this loop's third was the linked product, itself a Go program),
so "a third sequential exec from one EL0 parent" and "a third live Go runtime"
predict the same tombstone and nothing in the record separated them.
`tools/go/selfhost.go` gained an argv-gated measurement for it —
`--spawn <image> <count> [expected-status]`, plus `--after-loop` to put the
spawns behind the loop's own two children. It is off by default and no spec
asserts its verdict (pinning a bug's present shape into a class-B gate would
freeze it); the one-off trial lives in the gitignored `artifacts/`. Four boots
answered it:

| boot | children of the one EL0 parent | observed |
|---|---|---|
| 01 | 3 x Zig `STATUS43.BIN` (non-Go, exits 43) | 43 / 43 / 43 — 3-of-3 survived |
| 02 | 3 x Go `GOHELLO.ELF` (exits 0) | 0 / 0 / 0 — 3-of-3 survived |
| 03 | `cmd/compile` (24 MiB) then `cmd/link`, then 1 x Zig child | 2,000 ms + 9,006 ms, then 43 |
| 04 | `cmd/compile`, `cmd/link`, then the PRODUCT (the original failing shape) | 2,000 ms + 16,005 ms, then **status=0** |

So the child COUNT is not the rule, the child's LANGUAGE is not the rule, and
the once-observed death did not reproduce in the exact configuration that
produced it. What that leaves is narrower and less satisfying than either
hypothesis: the failure is intermittent, or something between the two heads
fixed it — one boot per configuration cannot separate those, and neither
`#1449`'s two original observations nor the tombstone above are withdrawn,
because they happened. **The honest statement is the narrow one: a third child
died once and has not died again; the wall is uncharacterised, not eliminated.**
The consequence for this card is a design note, not an excuse: the spec keeps
two children plus a monitor `exec` for the run because that shape is proven
green, not because three children are known to fail — and a single-boot
three-child loop is now feasible, and is the first thing to try once #1449 has
an owner. The report is posted on #1449.

One thing the measurement does NOT establish, stated because it is readable
both ways from the log: a step's `status=0` is a **liveness observation, not
proof**. The wait rule counts a pid that was seen running and then left the
registry as status 0 (`vi/proc.go`), which is also what a child that crashed
and was reaped between polls looks like. What proves the steps worked is
downstream and checked on the host — `HELLO.o`'s ar header names the virelai
target, and the product satisfies every loader rule before the second boot runs
it; in the measurement above, the Zig child returning its own 43 is the strong
half (a status the kernel could only have got from the program itself).

The driver's per-step wait budget is 600 s. It is a ceiling, not a prediction
(the measured steps are 2,000 ms and 14,016 ms), and it is deliberately BELOW
the gate's own `--timeout 900` for that boot: at the 900 s this first shipped
with, the driver's ceiling and the harness's kill expired together, so "wait
budget expired" was unreachable by construction and a reader would have got two
competing deadlines instead of an answer.

Two costs of the driver itself, named rather than hidden: it links `vi`
(`Exec`, `WaitBudget` and `Probe` are that package's surface — the wait rule
lives there ONCE and the driver passes its longer ceiling in, rather than
carrying a second copy that a fix in `vi` could not reach; `vsys` has no
spawn), so
`build-go.sh`'s gap-layout guard WARNs on it exactly as it does for
GOREAD/GOSYSCALL — the image nonetheless passes every loader rule the kernel
enforces, which is what the gate checks — and those numbers move with the file,
so they are re-measured rather than remembered: at this amendment's first head
it was 3 PT_LOAD, memsz 1,244,044, slack 0xbb0, and with the review fixups (the
shared waiter, the `--spawn` measurement) it is 3 PT_LOAD, memsz 1,252,164
(0x131b44), slack 0xb90 — every rule passing in both, read with
`tools/lib/elf_rules.py`, the same checker the two class-B specs run. The loop
also presumes ~15 MiB of archives in the share, which is the ingredient that
makes it a guest-side build rather than a guest-side invocation.

## Amendment 9 — what M70c (#1455) left opt-in, and why that is the acceptance

`cmd/compile`, `cmd/link`, the in-guest loop and the `live-selfhost-go` gate all
landed (#1543/PR #1551, #1544/PR #1552, `live-zc`'s S3 in PR #1511), and the card
closes on its own stated end: the gate is green. One deliverable is deliberately
NOT taken as written — its deliverable 1 says `GOVIRELAI_STD=1` "becomes the
normal path", and pass 2 (a fork-local `GOOS=virelai make.bash` std install)
is still opt-in in `tools/go/build-go.sh`.

The reason is that pass 2 is not on the acceptance's path. What the acceptance
asks for — the guest compiles, links and runs a guest program with its own tool
binaries — is reached through the `GOOS=virelai` port overlay (which is what
makes the default `GOOS=virelai` build of the toolchain images work at all) and
through `tools/go/stage-selfhost.sh`, whose own comment states the fact: the
`go list -export` closure "works on a fork whose std was only ever compiled,
never installed to pkg/". Nothing in the loop reads a fork-local virelai
`pkg/`; it reads the staged source and the staged archives.

So the flip buys the loop nothing and costs every guest fixture, because
`build-go.sh` is their default path and pass 2 would add a full std build to
every invocation. The blast radius is the guest build surface, not this card.
A later card that needs a virelai `pkg/` tree (an in-guest `go` driving builds,
say) owns the flip and the fork rebuild it implies. D4's boundary is unchanged:
the toolchain payload stays host-staged, and the one boot that still runs the
loop's product is a consequence of the uncharacterised third child in amendment
8, not of the toolchain's provenance.

## Amendment 10 — M72a (#1579): the acceptance bound splits into a file bound and a memory bound

The bound this ADR declares in its table ("ELF load bound") was one number
charged on `Σ p_memsz` (`kernel/src/elf.zig`, `load_max`). That made it a bound
on MAPPED memory wearing the name of a bound on file bytes, and it refused every
Go image carrying a large zero-initialized global, because `.bss`/`.noptrbss`
adds no file bytes at all: `crypto/internal/fips140/drbg`'s `var memory
entropy.ScratchBuffer` is 33,554,432 B of it (`crypto/internal/entropy/v1.0.0`,
`type ScratchBuffer [1 << 25]byte`), and it is in the closure of every
Charm-sized binary.

The card's premise — "demand-backed BSS is not charged as if it were resident" —
does not hold in this tree and the bound could therefore not simply be dropped.
This loader *eagerly* allocates and zeroes every mapped page
(`exec_static_elf_gap`: `alloc_pages(ceil(memsz / page_size))`, then a fill of
`[filesz..memsz]`), so `Σ memsz` is the RAM an image takes out of the pool before
its first instruction. *(True when written — card #3032 made the
zero-fill tail demand-paged; see Amendment 12.)* A 1 GiB `.bss` accepted here would have become an
`.out_of_memory` a moment later instead of a named refusal.

Two bounds, each named for what it charges:

| bound | charges | value | error (`elf.zig`) | `ExecResult` |
| --- | --- | --- | --- | --- |
| `load_max` | `Σ p_filesz` — the bytes read off the volume | 32 MiB (unchanged) | `segment_too_large` | `image_too_large` / `staging_too_large` as before |
| `map_max` | `Σ p_memsz` — the pages allocated and zeroed *(virtual span since card #3032 — Amendment 12)* | **64 MiB** | `map_too_large` (new) | `map_too_large` (new) |

`load_max` is now a parser-level invariant rather than the operative bound: the
segment file ranges are disjoint and inside the file (both still enforced), so
`Σ filesz ≤ file size ≤ exec_image_max` (32 MiB) for any caller that bounds the
file too. It stays because `parse`/`parse_head` are public entry points that do
not. **64 MiB** for `map_max` is frozen here against the pool rather than
against taste: `sysinfo`'s allocator line reads `free=0xde0b` (56,843 pages,
222.0 MiB) on a fresh boot and `free=0xb68c` (46,732 pages, 182.5 MiB) with the
boot apps up, so the bound admits a 2× FIPS scratch buffer plus the largest
Charm-sized image seen while leaving the image's own heap most of the guest.

Both totals are charged in the same loop as the per-segment checks, before any
placement check, so an oversized mapping is refused by the bound that names
MEMORY and never as `gap_too_high` (a statement about address space).

### What else moved, and why

* The oversized-file branch in `exec.zig` maps a parse error to its own name. It
  used to fall through to `.staging_too_large`, whose message —
  "…too large for the 0x200000-byte staging buffer (only a gap-layout static ELF
  streams past it)" — was printed about exactly that shape: a gap-layout static
  ELF that would have streamed. The new line says the map bound instead.
* The staged ELF branch's `mem_total(image) > exec_program_max` charge is now
  scoped to the shapes that really transit the buffer. `exec_static_elf_gap`
  copies only each segment's FILE bytes (already proven ≤ `program.len`), so a
  ≤2 MiB go binary whose segments map 50 MiB was being refused by the same false
  "staging buffer" sentence.
* `tools/lib/elf_rules.py` — the one host copy the two class-B specs
  (`go-hello` run 07, `live-selfhost-go` run 01) run against a GUEST-BUILT ELF —
  charged `Σ memsz` against `load_max`. Left alone it would have refused, from
  the host and before any boot, images the kernel had just been taught to accept;
  it now mirrors both bounds.
* The FIPS toolchain gate (`tools/go/build-gotool.sh`, `tools/go/apply.sh`) is
  KEPT, and `build-gotool.sh`'s rule check splits with the loader's. These two
  images' measured `Σ memsz` is 58,254,964 B, which fits the new bound by
  arithmetic — that is an inference, not a result: the unexcluded build has not
  been booted, and retiring the gate is its own decision with its own evidence.

### Evidence (observed, on this branch)

`go-hello` **PASS 12/12 runs** (102 s, all of runs 01-10 re-run as regression):

* run 11 — `tools/go/goloadbss.go`, 9,582,729 B on disk with `Σ filesz`
  9,451,012 B and `Σ memsz` 51,559,756 B (its RW segment: `filesz` 8,416,256,
  `memsz` 50,525,000, i.e. 42,108,744 B of `.noptrbss`). The old bound refused it
  as `segment_too_large`; it now execs and prints its own banner, reading the
  first and last byte of that 40 MiB tail back (`loadbss: scratch ends 1 2`), and
  the guest's `datapages=12337` equals `ceil(RW p_memsz / 4096) + 1` computed on
  the host from the same file — the argv+envp page included, so the mapping is
  held to the image's own headers rather than to a magic constant.
* run 12 — the same bytes with the RW `p_memsz` rewritten to 1 GiB:
  `HUGEBSS.ELF: image maps too much memory (map bound 0x0000000004000000 bytes;
  every PT_LOAD page is allocated and zeroed)`, with `serial-absent 'staging
  buffer'` and a `sysinfo` after it proving the monitor kept reading.

Class A: `zig build test` green — 4,185 tests, including the elf.zig loader tests
(they admit the 40 MiB-`.bss` gap fixture and refuse its 1 GiB twin as
`map_too_large`, asserting the refusal comes before placement) and a
`kernel/tests/monitor_test.zig` case for the newly scoped staged path (a
gap-layout image of 0x2100 B whose writable segment declares 3 MiB now EXECS on
the staged path with `datapages=769` and a free-page delta of 867, where the old
buffer charge refused it as `staging_too_large`). `zig fmt --check` clean, `just
verify-portable` exit 0
including `verify-bss-budget` (.bss 12,020,408 B / 13,631,488 B). Targeted class-B
regressions for the changed exec seam: `live-el0-exec` 1/1, `live-exec` 1/1.

## Amendment 11 — M119d (#2488): the third-child death, measured by shape — a bound, not a death

Amendment 8 left the debt named but uncharacterised: "a third sequential exec
from one EL0 parent died once and has not died again; the wall is
uncharacterised, not eliminated." This amendment is the characterisation the
debt owed: a spawn-shape matrix over one EL0 parent — sequential depth,
concurrent breadth, tree depth, and the exact failing shape — pinned as
permanent legs of the `live-exec` gate (runs 02-04), K=5.

The driver is the same `tools/go/selfhost.go` amendment 8 measured with, plus
two additions the matrix needed: `--spawn-par` (every child spawned before any
wait, so the pool holds them all live at once — the breadth leg) and `--`
(everything after it is the spawned child's own argv — a GOSELFHOST child
carrying `--spawn` is the tree-depth leg). Verdict lines name the image
(`verdict=K-of-M-survived IMAGE`) so each leg's end is a unique serial marker.

### The matrix, observed (VZ, this branch)

| shape | leg | children of the one EL0 parent | observed |
| --- | --- | --- | --- |
| sequential depth-5 | 02A | 5 x Zig STATUS43.BIN (exits 43) | 5-of-5 |
| sequential depth-5 | 02B | 5 x Go GOHELLO.ELF | 5-of-5 |
| tree depth-3 | 02C | GOSELFHOST -> `--spawn STATUS43.BIN 2` | parent 1-of-1, nested 2-of-2 |
| concurrent breadth-8 | 03A | 8 x Zig | 8-of-8 |
| concurrent breadth-12 | 03B | 12 x Zig | **9-of-12, three `SPAWN-FAIL err=ENOSPC`** |
| concurrent breadth-3 | 03C | 3 x Go GOHELLO.ELF | 0..2-of-3, dead children exit status=2 (`newosproc`) |
| amendment-8 exact shape | 04A | cmd/compile, cmd/link, then HELLO2.ELF | status=0, 5/5 — **the tombstone shape survives** |
| heavy pair + depth | 04B | compile, link, then 3 x Go | 3-of-3, 5/5 (in an earlier assert revision one pass saw `link ... status=2` under backlog) |
| heavy pair + breadth | 04C | compile, link, then 2 x Go concurrent | **0..2-of-2** — the bound fires most passes (zombie backlog + 2 x 4-task runtimes) |

### What the matrix says

- **The third-child death does not reproduce.** Across the legs' spawned
  children there are zero status=139 tombstones, zero `[EXC] parking:`, zero
  `cannot allocate memory`, zero wedges — including leg 04A, the exact
  configuration that produced amendment 8's `far=0x47c29000` abort. Between
  the two heads sits PR #2437's lifecycle chain — early user-page release at
  last-task exit, the populate-race retry, the scratch-table leak fix, and
  the toolchain's `virMunmap`/`GOMEMLIMIT` — which names the candidates for
  both observed deaths (a level-3 permission fault and a schedinit GC
  corruption, both explainable by freed-phys aliasing / false populate
  faults). The original observations are not withdrawn — they happened — but
  at this head the death is **unreproduced under the shape that produced it**,
  which is the strongest statement the matrix can make.
- **The residual bound is BREADTH, not depth — and it is the task pool, named
  twice.** `scheduler.max_tasks` = 16: three kernel tasks plus 13 user slots.
  A Go parent (4 Ms at the compiled GOMAXPROCS=2 default) plus nine one-task
  Zig children fills it exactly: the 10th+ `sys_exec` gets `pool_full` ->
  ENOSPC, observed as `SPAWN-FAIL` lines with the parent and the spawned
  nine unharmed (9-of-12, stable across passes). Under the same parent,
  concurrent Go children bound at 2: each runtime wants ~4 task slots of Ms,
  so the third's `newosproc` (sys_thread, slot 73) hits the dry pool inside
  schedinit and throws `sys_thread create failed` -> status=2 — a clean
  runtime refusal, not a tombstone. Which child draws the short straw is
  scheduler order, so the leg pins the refusal's SHAPE (verdict printed,
  statuses named) rather than a fixed count.
- **The bound is not positional — it can bite a sequential Go child too.**
  Once in the K-sweep, leg 04B's `link` — the SECOND child of a fresh driver —
  died `newosproc ... sys_thread create failed` -> status=2 at ms=1002, i.e.
  inside schedinit while the pool was still paying zombie backlog from the
  previous leg's toolchain children (the reaper drains one task per idle
  pass). "A third child dies" was never about the ordinal: it is "a Go
  runtime child spawned while the pool cannot serve its Ms". This is the
  named bound the card asks the ADR to record: `scheduler.max_tasks` vs live
  + zombie task demand, expressed as ENOSPC at `sys_exec` or a status-2
  `newosproc` death inside the child — both named, neither a wedge, neither
  the amendment-8 tombstone. It is also the same signature as the M112a/d
  `newosproc` transients, now with its pool accounting.
- **The matrix also surfaced and fixed a wait-side defect.** `sys_exec` can
  legitimately return pid 0 — `create_as` recycles the lowest free registry
  descriptor, and once the registry churns, slot 0 goes to live children —
  but `vi.Probe`/`vi.WaitBudget` treated `pid <= 0` as invalid, so a pid-0
  child ran to completion while the caller read EINVAL (observed twice in the
  matrix: the breadth leg's third Go child, `spawned pid=0`, and the nested
  leg's second grandchild). This is the "lost spawn" signature M112a/d saw
  (`sync_failed exec`) and `user/go/gobuild/spawn_guest.go`'s `waitChild`
  already carried a local workaround for it — the fix belongs in `vi`, where
  only a negative pid is now not a pid.

### Consequence

Amendment 8's conservative shape — two children plus a monitor `exec` for the
product — was kept "because that shape is proven green". Nothing in the matrix
says a third child dies: a one-boot three-child loop is unblocked as far as
this bound is concerned (the residual `GOGC`/pool sizing under sustained
toolchain churn is a different question, owned by the fleet drivers). The
named bound going forward is `scheduler.max_tasks` under concurrency —
refusals are ENOSPC at spawn or a status-2 `newosproc` death, both named,
neither a wedge.

## Amendment 12 — card #3032: `map_max` is a VIRTUAL bound, and resident pages are the honest count

Amendment 10's table froze `map_max` as "`Σ p_memsz` — the pages allocated
and zeroed", a RAM budget, because the gap loader really did allocate and
zero every mapped page before EL0 ran. That stopped being true in card
#3032: the loader now allocates and fills only the **file-backed** part of
each PT_LOAD (plus the argv/envp headroom in the last segment) and
registers the page-rounded `memsz − align_up(filesz)` tail as an image
demand-zero region — the same first-touch fault path anonymous mmap and
the user stack already took (`populate_user_page`, the `find_zero_region`
bookkeeping in `process.zig`). A Go image's untouched `.bss`/`.noptrbss` —
the 32 MiB FIPS `entropy.ScratchBuffer` this ADR exists because of — now
costs no RAM until it is written.

Two consequences for the bounds this ADR owns:

- **`map_max` stays, at 64 MiB, but it charges VIRTUAL span.** It is the
  address-space bound — how much of its own map one image may claim —
  exactly the role the "bound on MAPPED bytes" column always described,
  now honestly named. The resident side needs no new bound in its place:
  exec's eager part still refuses through the allocator's `out_of_memory`
  → ENOMEM path, and at fault time a dry pool makes `populate_user_page`
  deliver the fault rather than overcommit.
- **Resident pages are what the capacity table counts.** The exec line
  reports `datapages=` (resident at exec: file pages + the argv run) and
  `mappedpages=` (the virtual span); `procs` `mem_bytes` (ADR 0047 D5's
  `footprint_pages`) counts the resident subset — owned segment pages
  plus demand-faulted dynamic pages — so the figures the capacity table
  cites are pages that exist, not pages that were reserved.

The gates moved with the semantics, not around them: `go-hello` run 11 now
asserts `mappedpages` = `ceil(RW p_memsz/4096) + 1` and `datapages` ≤ the
file-backed count plus the argv run, and the 8 MiB leg asserts the
streamed data resident with the tail not — the same fixture, held to its
own headers in both directions. `go-panic` and `go-wm-default` pin the
fault path and the multi-runtime residency unchanged.
