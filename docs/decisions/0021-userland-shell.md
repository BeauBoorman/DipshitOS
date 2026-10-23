# ADR 0021: The userland shell and the kernel-monitor boundary

Status: **ACCEPTED** · Date: 2026-09-11 · Milestone: **M45** (userland shell &
terminal front-ends) · Issues **#1065**, **#1072**

> Commits the shell direction chosen in the 2026-09-10 triage and fixes the
> boundary that keeps it from regressing. Builds directly on ADR 0020 (the
> terminal seam, done) and the M19 shell-feature set.

## Context

The kernel monitor (`kernel/src/monitor.zig` + `kernel/src/shell.zig`) is the
only shell today: ~90 commands over the kernel console, in EL1. The terminal
seam (ADR 0020) now lets an EL0 process own a terminal (`/dev/tty`, attach the
serial console; `TERM.BIN`/remote front-ends reserved). The M19 work already
proved the interactive feature set (pipes, redirection, globs, `$()`,
`$(( ))`, `if`/`fn`/`for`/`while`, jobs, history, Ctrl+R, completion) — in the
kernel, where it cannot be hosted by a desktop window or reached over the
network without a kernel console bridge.

A shell is the thing the user wants. The question is not *whether* to move it
to userland; it is **what stays in the kernel** and **how the two coexist**
without a long-term ABI we have to claw back.

## Decision

### D1. Split, don't replace
The kernel monitor stays the **boot / recovery / diagnostic console** (the
UEFI-shell / BIOS-setup role) and keeps the raw serial console by default.
`SH.BIN` is the **user-facing shell**, an ordinary EL0 process on the terminal
seam. Both existing is healthy; users are only ever in one at a time, and the
prompt / a `monitor` escape make it explicit which.

### D2. The shell owns the terminal in userland
`SH.BIN` opens `/dev/tty`, attaches a front-end (`sys_tty_attach`, slot 67),
and owns line editing, history, completion, and command dispatch. Front-ends
(serial now; `TERM.BIN` window; TCP/SSH later) attach through the same seam —
the shell is written once (ADR 0020).

### D3. The command boundary (the thing that prevents claw-back)
- **User-facing** commands (files, processes, network, time, settings, `exec`)
  are implemented in userland via **existing syscalls** and/or small apps. The
  shell resolves externals from the host share with a PATH-like search.
- **Shell builtins** are only what needs shell state: `cd`, `exit`, `env`/
  `set`/`unset`/`export`, `alias`, `history`, `source`, `jobs`/`fg`, `prompt`.
  Keep the builtin set small.
- **Kernel-internal diagnostics stay in the monitor**: `mem`, `pages`, `pci`,
  `timer`, `syscalls`, `uaccess`, `fault`, `strace`, `sym`, `addrspaces`,
  `procs`-style kernel dumps. There is **no** "run a kernel command" syscall.
  When a probe is genuinely wanted in the shell, add a **structured syscall**
  returning data (the `sys_procs` model) — never a passthrough.
- **No kernel-shell-over-network.** Remote attaches a front-end to a userland
  shell's terminal, not to the monitor.

### D4. Scripting is ported, not reinvented
The M19 operator set moves to userland in phases (pipes via slots 56/57,
redirection, globs, `$()`/`$(( ))`, `if`/`fn`/`for`/`while`, `source`).
Semantics stay the M19 ones so existing scripts/docs carry over; the host
tests port with them.

### D5. Boot default is unchanged until proven
The monitor keeps the raw console. A settings key (`shell = monitor | sh`)
flips the raw-console login to `SH.BIN` **after** the shell's gates are green;
until then `SH.BIN` runs on demand (`exec SH.BIN`) or in `TERM.BIN`.

**Implemented 2026-09-11** (M45 card SH8, issue #1084, claim #1106):
`settings shell=monitor|sh` (default `monitor`) drives a boot login seam —
`shell=sh` execs `SH.BIN` and the monitor relinquishes the raw console (the
serial terminal front-end owns the RX; the monitor resumes if the shell
detaches). `SH.BIN` runs an optional `STARTUP.SH` and adopts the persisted
`prompt`. The class-B `live-shell-default` gate proves `shell=sh` lands in
`SH.BIN` and the untouched default lands in the monitor.

**Amended 2026-09-19** (M68b, #1450): the seat now execs `GOSH.ELF serial` —
the Go shell's serial front-end, which shares the engine, editor and startup
contract with its window path (ADR 0030/H1). The settings VALUE stays `sh`:
it names the seat, not the binary, so a persisted `SETTINGS.TXT` needs no
schema migration, and the boot default (`monitor`) is untouched. The kernel
execs the image by name in `login_handoff`; `live-shell-default` (boot-login
prompt adoption) and `live-sh-monitor` (the `monitor` escape back to the raw
console) are retargeted and green on VZ.

**Amended 2026-09-19** (M68b, #1450, final slice): `SH.BIN` is deleted.
`GOSH.ELF` is the user-facing shell on every front-end the Zig binary hosted
(serial, window, and `net [port] [open]` with the delegated HMAC
challenge-response handshake). `TERM.BIN` still exists as the Zig window
front-end; remote attach is `GOSH.ELF net`. The login argv array stays a
named runtime-built array (an anonymous comptime literal packed garbage
bytes; mechanism unisolated).

### D6. One shared userland terminal library
A `lib/tty.zig` (read/write `/dev/tty`, raw-ish line buffering, history,
completion) is shared by `SH.BIN` and the front-ends so behaviour cannot drift
between the serial, window, and remote presentations.

## Consequences

- The shell becomes hot-reloadable and crash-isolated; the kernel stays thin.
- `TERM.BIN` and remote/SSH become front-ends, not parallel shells.
- The monitor keeps all kernel-diagnostic power; the shell gets none by
  construction (a clean privilege story for the eventual remote session).
- Risk: feature drift between monitor and shell — mitigated by moving whole
  command families out of the monitor as their userland replacement lands, and
  by keeping the monitor's job definition to "diagnostics + recovery".

## Open issues (left to the M45 cards)

- The exact command-family migration order (march doc `march-m45-*`,
  condensed into `docs/archive/era-m0-m51.md`).
- Whether `procs`/`dui`/`wm`-style introspection becomes structured syscalls
  for the shell or stays monitor-only (card-by-card decision).
- Windows/remote front-end rendering (selector 2/3) — `TERM.BIN` + a TCP
  front-end, per ADR 0020.
- Whether the default-shell flip ships in M45 or a follow-up.
