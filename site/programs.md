---
title: Runtimes & demos
parent: capabilities
status: published
tags: [capabilities, userspace, runtimes, demos]
---

# Runtimes & demos

The product fleet — editors, browser, terminal, games — is catalogued
on [[apps]]. This page is about the **other** things that execute at
EL0: the interpreters and runtimes a program can target, the guest
ports that proved them, and the measured dead ends the project walked
into and documented honestly. Almost everything here is a Go ELF; the
exceptions are named.

## WebAssembly: `WASM.BIN`

`WASM.BIN` (`user/src/wasm.zig`, a retained Zig binary) is a bounded
wasm-core interpreter — parse, validate, execute — built to the zc
discipline: fixed buffers, zero heap, a file-scope `Machine` so the EL0
stack never carries state. The subset covers i32/i64/f32/f64, the full
block/loop/branch/call vocabulary plus `call_indirect`, saturating
truncations and bulk memory, exactly **one linear memory (2 MiB / 32
pages, backed by `sys_mmap` on demand)** and one function table.
Threads, atomics, SIMD, multi-memory and the wider `0xFC` opcode space
stay out; traps name themselves with module and byte offset.

What makes it more than a toy is the **frozen `env.*` import
contract**: 29 imports (`max_imports` 32 with headroom) that dispatch
each wasm call onto the ordinary ADR 0007 `svc #0` seam — file, window,
audio, timer, memory, process, debug, net, term capability names — so a
`zig cc -target wasm32-freestanding` or `rustc wasm32-unknown-unknown`
module does real I/O without WASI. The capstone is a real `wc` — the
Unix word-count compiled to wasm, running in-guest. A contract-v2
custom section (`virelai.abi`) carries capability names and a SHA-256
delivery manifest verified against the module bytes. Gates:
`live-wasm`, `live-wasm-abi`, `live-wasm-trap`.

## JavaScript (QuickJS)

The interpreter now ships as `QJS.BIN`, a standalone, bounded
**QuickJS** at native EL0 (ADR 0039): Fabrice Bellard's MIT-licensed
interpreter, pinned commit and
byte-hashed source manifest, built host-side with a Zig adapter and
private libc-free headers into a static AArch64 ELF. The bounding is
the interesting part — a checked C-statement pass inserts a propagating
work counter at every compiled function entry and loop iteration (a
10-million-site ceiling, separate from the engine's own), every SDK
allocation is charged through an arena, the C stack gets an AAPCS64
save/restore boundary with sticky refusal, and a maintained allocation
registry reclaims engine blocks after a refusal without running user
finalizers. Twenty-three cases run under `live-quickjs`, including a
warm-checkpoint boot.

It is deliberately **not** a browser engine: `WEB.ELF` never executes
JS — ADR 0028 D2 is permanent — and there is no DOM, no npm, no JIT,
no fetch.

## Bubble Tea over the window tty

The bound `/dev/tty` speaks enough VT for **Charm**: 16-colour SGR,
CUP/EL/ED, an alternate screen, DECTCEM, and SGR mouse. Landing that
took splitting the ELF loader's single bound into `load_max` (32 MiB of
*initialized* bytes) and `map_max` (64 MiB of *mapped* bytes) — a Go
image's giant `.noptrbss` costs zero file bytes but real RAM, and the
loader now refuses `map_too_large` by name instead of blaming a staging
buffer.

On that seam: `go-charmhello` runs a tiny Bubble Tea v2 model — two
Virelai-only platform stubs applied as compiler overlays over
module-cache source, never a vendor dump — and `BTMATH.ELF`
(`go-btmath`) proves the real `tea.Program` shape under `GOOS=virelai`.
The fleet adopts it where a TUI fits the app: GOFILES, GOHELP and
PULSE are all real `tea.Model`s fed by the kernel's bound-tty queue.

## Gostalgia as a guest

`GOSTALGIA.ELF` is the project's stranger proof: the owner's own
Gostalgia environment — apps, services, a shell — shipped as **one
static Go ELF** through module-cache overlays plus the `user/go/gsport`
adapters (`fsys`, `proc`, `sig`, `ipc`, `tty`, `vfs`), launching as
`shell --root /host/GS`. Gostalgia's own repo is untouched; every
dependency is a pinned MIT-licensed module whose notices ship in
`THIRD-PARTY.txt`. `go-gostalgia` (+ `-files`/`-proc`) journeys a cold
boot through a chord session, `fs/read`, and clean shutdown.

## The bounded native-Zig portfolio

ADR 0038 carved out exactly four approved native workloads —
host-built AArch64 EL0 through an owned SDK (stock pinned compiler,
narrowly patched freestanding stdlib, caller-owned arenas) — and
forbade everything else: no libc/POSIX shim, no second toolkit, no
full Zig self-hosting.

| Workload | What it proves |
|----------|----------------|
| Oliver render/meta | a real sibling-repo Zig CLI emits HTML/JSON byte-exactly in-guest (`live-oliver`) |
| k4o render | textile/markdown/gfm template+JSON rendering under output bounds (`live-k4o`) |
| Serial offline Boris | the static-site compiler that builds **this site**, running a serial offline build in-guest (`live-boris`) |
| fart synth | the actual `synth.zig` path emits a deterministic WAV (`live-zig-fart`; `go-fart` covers the unrelated Go FART app) |

B5 added explicitly bounded native threads — caller-owned TLS
contexts, single-use join/exit — without growing `std.Thread` or a
worker budget.

## Kept seam proofs

The Zig-era fixture fleet mostly retired as Go successors landed, each
one deleted with its gate coverage re-homed onto a Go successor:
deleted `EDIT.BIN`, `FILE.BIN`, `CALC.BIN`, `NOTEPAD.BIN`, `TOP.BIN`,
deleted `SYSMON.BIN`, `SETTINGS.BIN`, `HTTPD.BIN`, `VIEW.BIN`,
deleted `DOC.BIN`, `SH.BIN`, `PING.BIN`, `NETSTAT.BIN`, `DNS.BIN`,
deleted `TRACEROUTE.BIN`, `CHAT.BIN`, `SAVETEXT.BIN`, `TYPE.BIN`,
deleted `DIR.BIN`, `DESKTOP.BIN`, `FSTEST.BIN`. What
remains is what still proves a seam: the syscall-surface programs
(`USER`, `COUNTER`, `PEER`, `STATUS43`, `UDP`, `TCP`, `TIMER`,
`KEYTEST`, the `WIN*` family, `VICTIM`/`HARDEN`, `JINGLE`, `CHIME`),
the dev tools (`ASM`, `DISAS`, `PS`, `RESMON`, `DEVCONS`, `NETPROF`,
`VMTEST`), the dynamic-linking ecosystem (`LD.SO`, `LIBUI.SO`/
`LIBFONT.SO`, `DYNAPP.ELF`, `PLUGIN.SO` under `live-dynamic-linking`
and `live-dynamic-ecosystem`), and `TABWM.BIN` — retained permanently
as the Zig fallback seat (ADR 0034), not a leftover. `live-snake`
still plays snake.

## The honest negative results

Two dead ends are documented because the measurements were real:

- **JS inside WASM was tried and measured.** The Elk engine at
  22,763 bytes inspects clean — and its `exec` traps at the
  interpreter's `max_frames = 32` call-depth bound, while
  MIT-licensed engines need more than the 64 KiB linear-memory slice
  or wasm exception handling the interpreter does not implement.
  ADR 0028 D2 was amended with the numbers; raising the caps to admit
  an engine requires a new ADR, and the bounded QuickJS route is what
  shipped instead.
- **Go-on-WASM stays deferred.** `GOOS=wasip1` modules import
  `wasi_snapshot_preview1`, not `env.*`, and a WASI shim was
  documented but never built — the import surface stays ADR-0007
  shaped, not POSIX shaped.

<Aside kind="info">

**LIVE-GATED.** Every runtime on this page runs under a declarative
gate: `live-wasm`, `live-quickjs`, `go-charmhello`, `go-btmath`,
`go-gostalgia`, `live-oliver`, `live-k4o`, `live-boris`,
`live-zig-fart`, `live-snake`, `live-dynamic-linking` —
`just gate <id>` on Apple silicon.

</Aside>
