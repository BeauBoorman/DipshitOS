# Component registry (M189a, #3225)

One table of every shipped component: name, kind, binary, the one version
surface that answers "what version is it", the owning gate spec or contract,
and its state. Checked by `tools/tests/test_component_registry.py`, which
runs in `just verify-portable` — a row that disagrees with `image/apps.txt`,
with a spec pin it cites, or with the release grammar fails the build.

## The version rule

"Version" names exactly one surface per kind, and that surface only. A
shipped **app**'s version is its seat-stored state envelope `appver` — the
`StateVersion` the app registers with the tabapp harness in its package
under `user/go/`; an app that never saves state has no version surface and
shows `—`. A **store release**'s version is the signed `ReleaseVersion`
const in the head release manifest of its FLINT stream (ADR 0055 D2) — that
versions the release, never the app binary itself. A **kernel service** or
shared-format **contract**'s version is the ADR number that pins it. The
**kernel image**'s version is the `osver` build stamp (`-Dos-version`,
`kernel/src/osver.zig`). A **shared library** has no version of its own
unless it implements a contract — then the contract's ADR is the surface.
A pinned external **host tool**'s version is its pin file.

Scope: every `image/apps.txt` row, the seat and the tools the session
stages beside it, the generated ELF fixtures, the shared libraries under
`user/go/` and `user/src/lib/`, the kernel services that own a contract,
and the host tools the system cannot boot or publish without. A Go or Zig
program that is buildable but never staged (a `tools/go/build-*.sh` dev
tool, a gate-only Zig .BIN fixture) is not a component and is not
listed — the fleet's per-gate fixtures belong to their specs.

## Shipped apps (image/apps.txt)

Every row below is a manifest row — `app` means "has an `image/apps.txt`
entry", which is also what the drift check enforces in both directions.
All of them additionally answer to the schema-v2 manifest grammar
(`image/apps.txt` header).

| name | kind | binary | version | owning spec / contract | state |
|------|------|--------|---------|------------------------|-------|
| 64-bit Calc | app | GOCALC.ELF | appver 1 | tools/gate/specs/go-calc.spec | shipped |
| Text Editor | app | NOTE.ELF | — | — | shipped |
| Code Editor | app | GOEDIT.ELF | appver 1 | tools/gate/specs/go-edit.spec | shipped |
| Files | app | GOFILES.ELF | appver 1 | tools/gate/specs/go-fileman.spec | shipped |
| Terminal | app | GOTERM.ELF | appver 2 | tools/gate/specs/go-term.spec | shipped |
| Web | app | WEB.ELF | appver 1 | tools/gate/specs/live-web.spec | shipped |
| Pulse | app | PULSE.ELF | — | — | shipped |
| Shell | app | GOSH.ELF | — | tools/gate/specs/go-sh.spec | shipped |
| Help | app | GOHELP.ELF | — | tools/gate/specs/go-help.spec | shipped |
| Welcome | app | GOWELCOME.ELF | — | — | shipped |
| Top | app | GOTOP.ELF | — | tools/gate/specs/go-top.spec | shipped |
| Settings | app | GOSET.ELF | — | tools/gate/specs/go-settings.spec | shipped |
| Image Viewer | app | GOVIEW.ELF | — | tools/gate/specs/live-image-viewer.spec | shipped |
| Sound | app | GOSOUND.ELF | — | tools/gate/specs/live-sound-playback.spec | shipped |
| Tabbed Desktop | app | TABWM.BIN | — | tools/gate/specs/live-tabwm.spec, ADR 0034 | retained-fallback |
| Gostalgia | app | GOSTALGIA.ELF | — | tools/gate/specs/go-gostalgia.spec | shipped |
| Store | app | GOSTORE.ELF | — | tools/gate/specs/go-gostore.spec | shipped |
| LLM Infer | app | GOINFER.ELF | — | tools/gate/specs/live-gpu3d.spec | shipped |
| Recorder | app | GOREC.ELF | — | tools/gate/specs/live-sound-record.spec | shipped |
| Snapshots | app | GOSNAP.ELF | — | tools/gate/specs/go-snap.spec | shipped |
| Assistant | app | GOASSIST.ELF | appver 2 | tools/gate/specs/go-assist.spec | shipped |
| Sheet | app | GOSHEET.ELF | appver 2 | tools/gate/specs/go-sheet.spec | shipped |
| Reader | app | GOREADER.ELF | appver 2 | tools/gate/specs/go-reader.spec | shipped |
| Clock | app | GOCLOCK.ELF | appver 1 | tools/gate/specs/go-clock.spec | shipped |
| Mines | app | GOMINE.ELF | appver 2 | tools/gate/specs/go-games.spec | shipped |
| Solitaire | app | GOSOL.ELF | appver 2 | tools/gate/specs/go-games.spec | shipped |
| Emoji | app | GOEMOJI.ELF | appver 2 | tools/gate/specs/go-emoji.spec | shipped |
| IRC | app | GOIRC.ELF | appver 3 | tools/gate/specs/go-irc.spec | shipped |
| Vault | app | GOVAULT.ELF | appver 1 | tools/gate/specs/go-vault.spec | shipped |
| Mail | app | GOMAIL.ELF | — | tools/gate/specs/go-mail.spec | shipped |
| Accessibility | app | GOA11Y.ELF | — | tools/gate/specs/go-wm-journey.spec | shipped |

## Seat and staged tools

The session share (`tools/session.sh`) stages these beside the manifest:
the Go seat that is the boot default, the persistence tools the app-bound
credentials name, and the generated fixtures the exec/dyn-link gates run.
None is a catalog app, so none carries an `appver` column entry — the
seat owns the envelope, it does not ride in one.

| name | kind | binary | version | owning spec / contract | state |
|------|------|--------|---------|------------------------|-------|
| Tabbed desktop seat | seat | GOTABWM.ELF | ADR 0033 | tools/gate/specs/go-wm-seat.spec, ADR 0033 | shipped |
| OS updater | tool | GOUPD.ELF | — | tools/gate/specs/live-os-update.spec | staged |
| Agent daemon | tool | AGENTD.ELF | — | tools/gate/specs/go-agentd.spec, ADR 0044 | staged |
| Diff tool | tool | GODIFF.ELF | — | tools/gate/specs/go-godiff.spec | staged |
| Release pipeline | tool | GORELEASE.ELF | ADR 0055 | ADR 0055 | staged |
| WASM runtime | tool | WASM.BIN | — | docs/wasm-import-contract.md, tools/gate/specs/live-wasm.spec | staged |
| Zig userland root | tool | USER.BIN | — | ADR 0034 | retained-fallback |
| Sexiburger desktop | tool | SEXIBURG.BIN | — | tools/gate/specs/live-sexiburger.spec, ADR 0034 | retained-fallback |
| Hello fixture | fixture | HELLO.ELF | — | tools/gate/specs/go-hello.spec | fixture |
| Crash fixture | fixture | CRASH.ELF | — | tools/gate/specs/live-crash-viewer.spec | fixture |
| Dyn-link fixture set | fixture | DYNAPP.ELF | — | tools/mkdyn-elf.py, tools/gate/specs/live-dynamic-linking.spec | fixture |

## Shared libraries — user/go

Importable packages under `user/go/` (every directory whose `.go` files
are not `package main`). No version surface of their own unless one is
listed; the contract column names the ADR or spec their behaviour answers
to where one exists.

| name | kind | binary | version | owning spec / contract | state |
|------|------|--------|---------|------------------------|-------|
| appkit | lib | — | — | ADR 0011 | shipped |
| chords | lib | — | — | — | shipped |
| clockfmt | lib | — | — | — | shipped |
| css | lib | — | — | ADR 0028 | shipped |
| draw | lib | — | — | ADR 0011 | shipped |
| ed25519 | lib | — | — | ADR 0023 | shipped |
| fatimg | lib | — | — | ADR 0055 | shipped |
| find | lib | — | — | — | shipped |
| flate | lib | — | — | — | shipped |
| gpu3d | lib | — | — | ADR 0053 | shipped |
| heap | lib | — | — | — | shipped |
| hostint | lib | — | — | ADR 0051 | shipped |
| httpc | lib | — | — | — | shipped |
| ical | lib | — | — | — | shipped |
| icons | lib | — | — | — | shipped |
| ime | lib | — | — | — | shipped |
| infer | lib | — | — | — | shipped |
| layout | lib | — | — | — | shipped |
| linebuf | lib | — | — | — | shipped |
| mime | lib | — | — | — | shipped |
| observe | lib | — | — | ADR 0043 | shipped |
| outbox | lib | — | — | ADR 0051 | shipped |
| pcm | lib | — | — | ADR 0046 | shipped |
| pdf | lib | — | — | ADR 0040 | shipped |
| pdfproof | lib | — | — | ADR 0040 | fixture |
| pdfwrite | lib | — | — | ADR 0040 | shipped |
| prof | lib | — | — | — | shipped |
| rfb | lib | — | — | ADR 0045 | shipped |
| settings | lib | — | — | tools/gate/specs/live-settings.spec | shipped |
| shlib | lib | — | — | ADR 0044 | shipped |
| snapshot | lib | — | — | — | shipped |
| sshlib | lib | — | — | ADR 0025 | shipped |
| store | lib | — | ReleaseVersion | ADR 0055 | shipped |
| strace | lib | — | — | — | shipped |
| supervise | lib | — | — | ADR 0042 | shipped |
| svcgraph | lib | — | — | ADR 0042 | shipped |
| svcmanifest | lib | — | — | ADR 0042 | shipped |
| svg | lib | — | — | ADR 0041 | shipped |
| svgproof | lib | — | — | ADR 0041 | fixture |
| tabapp | lib | — | — | ADR 0033 | shipped |
| teatty | lib | — | — | ADR 0020 | shipped |
| theme | lib | — | — | — | shipped |
| timesync | lib | — | — | ADR 0060 | shipped |
| tls | lib | — | — | ADR 0029 | shipped |
| ttf | lib | — | — | — | shipped |
| vcard | lib | — | — | — | shipped |
| vector | lib | — | — | ADR 0041 | shipped |
| vectorconsumer | lib | — | — | ADR 0041 | fixture |
| vi | lib | — | — | — | shipped |
| vsockctl | lib | — | — | ADR 0056 | shipped |
| vsys | lib | — | — | — | shipped |
| webrender | lib | — | — | ADR 0028 | shipped |
| webstyle | lib | — | — | ADR 0028 | shipped |
| widgets | lib | — | — | ADR 0011 | shipped |

## Shared libraries — user/src/lib

Zig library units under `user/src/lib/` (one row per top-level file or
subdirectory package).

| name | kind | binary | version | owning spec / contract | state |
|------|------|--------|---------|------------------------|-------|
| action_registry.zig | lib | — | — | — | shipped |
| asmenc.zig | lib | — | — | — | shipped |
| crc32.zig | lib | — | — | — | shipped |
| crypto.zig + crypto/ | lib | — | — | ADR 0023 | shipped |
| fixtures/ | lib | — | — | — | fixture |
| flate.zig | lib | — | — | — | shipped |
| font8x8.zig | lib | — | — | — | shipped |
| font_atlas_gen.zig | lib | — | — | — | shipped |
| font_ttf.zig | lib | — | — | — | shipped |
| image.zig | lib | — | — | — | shipped |
| netargs.zig | lib | — | — | — | shipped |
| netauth.zig | lib | — | — | — | shipped |
| netstats.zig | lib | — | — | — | shipped |
| netstatus.zig | lib | — | — | — | shipped |
| pipe.zig | lib | — | — | — | shipped |
| png.zig | lib | — | — | — | shipped |
| qoi.zig | lib | — | — | — | shipped |
| rng.zig | lib | — | — | — | shipped |
| script.zig | lib | — | — | ADR 0021 | shipped |
| sexiburger.zig | lib | — | — | ADR 0034 | retained-fallback |
| shell.zig | lib | — | — | ADR 0021 | shipped |
| smpst.zig | lib | — | — | — | fixture |
| ssh/ | lib | — | — | ADR 0025 | shipped |
| startup.zig | lib | — | — | — | shipped |
| stdz/ | lib | — | — | — | shipped |
| tabapp.zig | lib | — | — | ADR 0033 | shipped |
| tls/ | lib | — | — | ADR 0029 | shipped |
| toolbox.zig | lib | — | — | — | shipped |
| tty.zig | lib | — | — | ADR 0020 | shipped |
| ui.zig + ui/ | lib | — | — | ADR 0011 | shipped |
| zc.zig | lib | — | — | tools/check-zc-host-contract.py | shipped |

## Kernel services owning a contract

Kernel-resident services whose cross-component behaviour is pinned by an
ADR or a contract doc. The version surface is the contract itself: when
the ADR is amended, the number in this table is what changed.

| name | kind | binary | version | owning spec / contract | state |
|------|------|--------|---------|------------------------|-------|
| Kernel image | kernel-service | KERNEL.BIN | osver | ADR 0004 | shipped |
| Boot loader | kernel-service | BOOTAA64.EFI | — | ADR 0001 | shipped |
| Syscall ABI | kernel-service | — | ADR 0007 | ADR 0007, ADR 0013 | shipped |
| exec / ELF loader | kernel-service | — | ADR 0035 | ADR 0035, ADR 0038 | shipped |
| Process model (sys-procs) | kernel-service | — | ADR 0047 | ADR 0047, ADR 0048 | shipped |
| Event delivery | kernel-service | — | ADR 0009 | ADR 0009 | shipped |
| Window server | kernel-service | — | ADR 0015 | ADR 0015, ADR 0018 | shipped |
| Terminal seam | kernel-service | — | ADR 0020 | ADR 0020 | shipped |
| File table / userland FS ABI | kernel-service | — | ADR 0010 | ADR 0010 | shipped |
| Network stack | kernel-service | — | ADR 0057 | ADR 0012, ADR 0057 | shipped |
| GPU / compute broker | kernel-service | — | ADR 0053 | ADR 0053 | shipped |
| Audio / PCM | kernel-service | — | ADR 0046 | ADR 0046 | shipped |
| Measurement + grants + manifest caps | kernel-service | — | ADR 0054 | ADR 0054, ADR 0024 | shipped |
| VLFS filesystem | kernel-service | — | ADR 0050 | ADR 0050, ADR 0061 | shipped |
| vsock-ctl channel | kernel-service | — | ADR 0056 | ADR 0056 | shipped |
| Host-integration lane | kernel-service | — | ADR 0051 | ADR 0051 | shipped |
| Warm checkpoint cooperation | kernel-service | — | ADR 0059 | ADR 0059 | shipped |
| Time and timers | kernel-service | — | ADR 0060 | ADR 0060 | shipped |

## Host tools

The host-side pieces the system cannot boot, image, or publish without.
`binary` names the in-repo source root.

| name | kind | binary | version | owning spec / contract | state |
|------|------|--------|---------|------------------------|-------|
| VMRunner | host-tool | host/vm-runner | — | docs/vz-runner.md | host |
| mkfs.vlfs | host-tool | tools/go/vlfs | ADR 0050 | ADR 0050, ADR 0061 | host |
| boris (docs site toolchain) | host-tool | tools/zig/boris | pin .github/boris-pin.json | .github/workflows/docs-gate.yml | host |

## Row grammar (what the drift check reads)

Every `|`-delimited line with six cells is a registry row; the check skips
the header and separator lines. Cells, in order:

- **name** — free text.
- **kind** — `app` (an `image/apps.txt` row), `seat`, `tool` (a staged
  guest binary), `fixture`, `lib`, `kernel-service`, `host-tool`.
- **binary** — the staged name (`NAME.ELF`/`NAME.BIN`/`NAME.SO`/`NAME.EFI`)
  or `—`. For `app` rows it must appear in `image/apps.txt`; for `seat`,
  `tool`, `fixture` and `kernel-service` rows it must be produced by the
  build or staging path (build.zig, `image/`, `tools/`); `lib` rows carry
  `—`; `host-tool` rows name their in-repo source root, which must exist.
- **version** — comma-separated tokens: `appver N` (the app's registered
  `StateVersion` under `user/go/`), a `Release`-prefixed const (one of
  the ADR 0055 grammar names in `user/go/store/release.go`), `ADR NNNN`,
  `osver`, `pin <path>`, or `—`.
- **owning spec / contract** — comma-separated refs: a
  `tools/gate/specs/*.spec` path, `ADR NNNN` (a file under
  `docs/decisions/` with that number must exist), another repo path that
  must exist, or `—`.
- **state** — `shipped`, `staged`, `fixture`, `retained-fallback`, `host`.

The check (`tools/tests/test_component_registry.py`, in
`just verify-portable`) fails when: an `image/apps.txt` row lacks a
registry `app` row or vice versa; a cited spec, ADR, const, or path does
not resolve; a binary is not in the produced set; an `appver` value
disagrees with the `StateVersion` the app's package registers (in either
direction — a new registration with a `—` here is drift too); or a cell
uses a token outside this grammar.
