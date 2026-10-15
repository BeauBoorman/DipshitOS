# btmath — Bubble Tea on VirelaiOS

`BTMATH.ELF` is a Bubble Tea program (`charm.land/bubbletea/v2`, pinned v2.0.9)
running as a **VirelaiOS userland app** under `GOOS=virelai`, `GOARCH=arm64`.

It exists to answer one question with evidence: *can we use Bubble Tea on this
operating system?* Nothing in the framework is reimplemented. The same
`tea.Model` / `Init` / `Update` / `View` program, the same `tea.Cmd` plumbing,
the same key decoding and `WindowSizeMsg` handling run here; only the two I/O
seams come from the guest.

Unlike charmhello/files/pulse — which own their loop and drive a `tea.Model`
by hand — btmath runs Bubble Tea's **real `Program`** (`tea.NewProgram` +
`program.Run()`), so the framework's own input reader, renderer, and resize
watcher execute in the guest.

## What the OS supplies

| Bubble Tea seam | VirelaiOS backend |
|---|---|
| Input (`tea.WithInput`, an `io.Reader`) | `keyScript` — a paced byte script, fed through Bubble Tea's real key decoder |
| Output (`tea.WithOutput`, an `io.Writer`) | `consoleWriter` — the kernel console (`vi.Console`) |
| Window size | `tea.WithWindowSize(80,24)`; a VirelaiOS console is not a POSIX tty to `ioctl` a size from, and Bubble Tea still delivers it as a `WindowSizeMsg` |
| Platform hooks | the M72c compiler overlay (`tools/go/overlay/charm/`), applied over module-cache source at build time |

## The port: platform hooks via overlay, not vendor

Upstream Bubble Tea defines its terminal hooks only for the OSes it ships, so
`GOOS=virelai` needs four symbols: `initInput`, `listenForResize`,
`suspendProcess`, `suspendSupported` (plus `checkOptimizedMovements`).

M72c settled the mechanism: **compiler overlays over module-cache source,
never an in-tree vendor dump.** The shims live in
`tools/go/overlay/charm/`:

- `termios_virelai.go` — `initInput` (no termios to capture), no-op
  `checkOptimizedMovements`, `suspendSupported = false`, `suspendProcess() {}`.
- `signals_virelai.go` — `listenForResize`: polls the process's ADR 0009 event
  queue for `WIN_RESIZE` and maps kernel pixel rects onto terminal cells.

`tools/go/build-btmath.sh` stages Bubble Tea v2.0.9 from the Go module cache
into gitignored `.build/`, points a transient `-modfile` at it, and builds
with `-overlay` replacing the two upstream files. Nothing third-party is
committed to this tree.

## Layout

```
user/go/btmath/{main.go,model.go}   the app
user/go/btmath/THIRD-PARTY.txt      license notices for the linked modules
tools/go/build-btmath.sh            the guest build
tools/gate/specs/go-btmath.spec     the live-VZ gate
```

## Build

```sh
bash tools/go/build-btmath.sh      # -> .build/go/BTMATH.ELF
```

Needs the `GOOS=virelai` fork toolchain (`tools/go/apply.sh && just go-toolchain`).

## Run (in the guest)

```
exec BTMATH.ELF
exec BTMATH.ELF --keys 1,7,ret --out /host/BTMATH/SESSION.TXT
exec BTMATH.ELF --window        # frames into a real TABWM window via /dev/tty
```

Flags: `--rounds`, `--seed`, `--keys`, `--out`, `--w`, `--h`, `--window`,
`--key-delay`, `--sink stdout` (for host runs, where the guest console
degrades to ENOSYS).

## Proof

- Built for `virelai/arm64` it produces a static aarch64 ELF inside the M72a
  loader bounds (32 MiB initialized / 64 MiB mapped).
- `tools/gate/specs/go-btmath.spec` asserts the run on VZ, ending with a
  **host-side read** of `/host/BTMATH/SESSION.TXT`, so a stub that printed
  markers without playing the game cannot pass.

## Proven on VirelaiOS

    exec: loaded BTMATH.ELF entry=...
    btmath: start
    Bubble Math  (Bubble Tea on VirelaiOS)
    ... Correct. +10 points / Not quite: 5, not 6. / Skipped. ...
    Session over. Final score 65.
    btmath: saved /host/BTMATH/SESSION.TXT 92B
    btmath: round played=5 score=65 correct=3 wrong=2
    btmath: OK

and the guest wrote `/host/BTMATH/SESSION.TXT`, read back on the host.

## Verifying it — inside the guest, with no shell

VirelaiOS has no bash, no `sh`, no libc and no Unix tooling. `BTMATH.ELF` is a
**static ELF with no `PT_INTERP`** — no dynamic loader, no libc — and its
entire OS surface is six calls into the guest SDK:

| call | used for |
|---|---|
| `vi.Console` / `vi.ConsoleLine` | frames and markers, straight to the kernel console |
| `vi.FileOpen` / `vi.FileWriteAll` / `vi.FileClose` | the session record in the host share |
| `vi.Exit` | the exit status |

No `exec`, no fork, no `PATH` lookup, no `#!/bin/sh`. So the proof runs *in*
the guest — you type one line at the `virelai>` monitor and read the verdict
off the console:

    virelai> exec BTMATH.ELF --selftest

The app plays the scripted session through Bubble Tea and then checks its own
results, printing one line per check:

    btmath: selftest begin checks=12
    btmath: selftest rounds got=5 want=5 PASS
    btmath: selftest score got=65 want=65 PASS
    ...
    btmath: selftest RESULT PASS checks=12 failed=0

Exit status 0 on PASS, 1 on any failure, so it also works unattended in a gate.
`--selftest` adds no dependency: it is the same binary, the same seams.

**Inert dependency code, disclosed.** Two module-cache sources —
`charm.land/bubbletea/v2/exec.go` (`tea.ExecProcess`) and
`github.com/charmbracelet/colorprofile/env.go` — reference `os/exec`, and both
are compiled in unconditionally. Neither is called by this app or anywhere on
Bubble Tea's own render/input path, so nothing forks; but the code is present,
and if it were ever invoked on VirelaiOS it would fail. Stated rather than
hidden.

**Host-side scripts are build tooling, not runtime.** `tools/go/build-btmath.sh`
and the gate spec are bash because every build and gate in this repository is;
they compile the artifact and boot the VM from macOS. They are never needed
inside the guest, and nothing they do is required for the app to run.

### What each layer proves

| Layer | Command | Runs where | Proves |
|---|---|---|---|
| Self-check | `exec BTMATH.ELF --selftest` | **in the guest** | the app plays the session and its results are what it claims |
| Gate | `just gate go-btmath` | macOS + VZ | the same, on a real boot, plus a host-side read of the record |
| Build | `bash tools/go/build-btmath.sh` | macOS | the artifact compiles for `GOOS=virelai` |
