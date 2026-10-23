> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# M45 — Userland shell & terminal front-ends (march tracker)

Umbrella: [#1067](https://github.com/drawmeanelephant/DipshitOS/issues/1067) ·
Milestone: [GH 32](https://github.com/drawmeanelephant/DipshitOS/milestone/32) ·
Design: [ADR 0021](../decisions/0021-userland-shell.md) (on the
[ADR 0020](../decisions/0020-terminal-seam.md) terminal seam, done) ·
Claim rule: `AGENTS.md` — one `claim` issue per card before code.

## Where we are

M45 is **complete** (SH1–SH8). The terminal seam (ADR 0020) now has serial,
window (Amendment A), and net (Amendment B) front-ends; the userland shell runs
on it — `SH.BIN` on the serial console or a remote TCP session, `TERM.BIN` in a
TABWM window — over the shared `lib/shell.zig` + `lib/tty.zig` core (M19 feature
set: completion, history search, pipes/globs, scripting). `settings shell=sh`
flips the boot login from the monitor to `SH.BIN` (the default stays the
monitor). The kernel monitor remains the boot/recovery/diagnostic console.

## The cards, in order

| # | Card | Goal | Acceptance | Touches |
|---|------|------|-----------|---------|
| SH1 | **`lib/tty.zig`** | One userland terminal library: open `/dev/tty`, attach a front-end, raw-ish byte read/write, a line editor (insert/delete, Home/End, Up/Down history), history store. Pure logic host-tested; the syscall glue thin. | Host tests (line editing, history ring, key decoding) + a `live-ttyecho`-shaped smoke that SH1's demo binary echoes an edited line. | `user/src/lib/tty.zig`, `user/src/lib/ui*` glue, `build.zig`, a demo app |
| SH2 | **`SH.BIN` core** | The shell process: attach the serial front-end, prompt, read a line via SH1, dispatch: builtins (`cd`, `exit`, `env`/`set`/`unset`/`export`, `alias`, `history`, `jobs`/`fg`, `prompt`, `source`) + external `exec` of share apps with a PATH-like search. Port the M19 line/dispatch structure. | class-A host tests (parsing, builtins, dispatch); class-B `live-sh`: type `echo hi`, `cd`, run an app, History Up. | `user/src/sh.zig`, `user/src/lib/tty.zig`, `build.zig`, `tools/gate/specs/live-sh.spec` |
| SH3 | **Completion + history search** | Tab completion (builtins, share apps, paths) and Ctrl+R reverse-i-search, ported from the M19 editor. | class-A completion/search tests; class-B asserts a completion and a reverse-search hit. | `user/src/lib/tty.zig` or `user/src/lib/complete.zig`, `user/src/sh.zig` |
| SH4 | **Pipes, redirection, globs** | `|`, `>`, `>>`, `<`, and `*`/`?`/`[a-z]` on the existing pipe slots (56/57) and file syscalls. | class-A operator/glob tests; class-B `echo hi | ...` and a redirect to the share. | `user/src/sh.zig`, `user/src/lib/pipe.zig` (new, userland) |
| SH5 | **Scripting** | Variables, `if`/`fn`/`for`/`while`, `$()`/`$(( ))`, `source`, exit status/`$?`, `&&`/`||`/`;` — M19 semantics. | class-A script tests (port the M19 suites); class-B a script file from the share. | `user/src/sh.zig`, `user/src/lib/script.zig` |
| SH6 | **`TERM.BIN` window front-end** | A TABWM terminal window that renders a shell's terminal (front-end selector `2`). Design landed: [ADR 0020 Amendment A](../decisions/0020-terminal-seam.md) (owner attaches its own `.user` window; kernel-pumped rings; kernel-side text grid; window keys → terminal input via `hid_to_bytes`; close auto-detaches). | Design note ✅ (ADR 0020 Amendment A) + class-B: a terminal window shows the shell and accepts typed keys (via the WM input seam). | `user/src/term.zig`, `kernel/src/terminal.zig`, `kernel/src/input.zig`, `kernel/src/driving_award.zig`, kernel window/attach path, a spec |
| SH7 | **Remote front-end** | A TCP session attaches front-end selector `3` to a shell (remote-in without SSH first). Implemented 2026-09-11 (claim #1102): [ADR 0020 Amendment B](../decisions/0020-terminal-seam.md) (owner-hosted, kernel-pumped listener via `sys_tty_attach(3, port)`; plaintext trusted-network posture; disconnect auto-detach; host→guest inbound gate via a runner TCP-client seam). Ties into #1066 Stage 1; SSH later rides the same seam. | class-B: connect TCP, drive the shell, see output. | `user/src/sh.zig` net presentation, `kernel/src/terminal.zig`, `host/vm-runner`, a spec |
| SH8 | **Default-shell flip + polish** | `settings set shell sh|monitor`; STARTUP file; prompt/themes; docs. Flip the raw-console login to `SH.BIN` only after SH2–SH5 are green. **Implemented 2026-09-11 (claim #1106)**: `settings shell` key + boot login handoff (`kernel/src/shell.zig`), `STARTUP.SH` + `prompt` adoption in `SH.BIN`; `live-shell-default` proves `shell=sh` lands in `SH.BIN` and the untouched default stays the monitor. | class-B: a boot with `shell=sh` lands in `SH.BIN`; the default stays the monitor. | `kernel/src/shell.zig`/`main.zig` (login seam), `user/src/sh.zig`, `docs/` |

## Dependency phases

1. **A — on the wire (SH1 → SH2).** A shell that runs on the serial front-end
   and runs apps. This is the "something I want to use" milestone payoff.
2. **B — parity (SH3 → SH4 → SH5).** Interactive depth + scripting, matching
   M19 so existing habits/scripts carry over.
3. **C — front-ends (SH6, SH7).** Window and remote presentations. Both are
   design-first (ADR 0020 amendment) and independent of A/B.
4. **D — default (SH8).** Flip the login only once A–C prove out.

## Risks / must-observes

- **Scope creep vs the monitor.** Do not build a "run monitor command" bridge;
  migrate whole command families as their userland replacements land (ADR 0021
  D3). Kernel diagnostics stay in the monitor.
- **Front-end multi-writer.** SH6/SH7 need a clear rule for one front-end at a
  time (the terminal object already forbids two) and for detach on close.
- **Boot regression.** The default path must stay the monitor until SH8; every
  existing live gate must stay green through A–C (boot default unchanged).
- **Console noise.** Live SH gates must emit markers in single writes (the SMP
  heartbeat can split lines — learned in `live-ttyecho`).

## Out of scope for M45

- SSH/TLS/crypto (that is #1066 Stage 2/3 on top of this).
- Replacing the kernel monitor or deleting its diagnostics.
- A top tab strip (the rail is the confirmed layout, #1064).
