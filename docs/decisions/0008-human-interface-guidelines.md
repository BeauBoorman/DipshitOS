# ADR 0008: Human interface guidelines (shell, windows, support)

Status: **accepted** · Date: 2026-08-14 · Milestone: eight (usability)

## Context

Milestones zero through seven shipped a complete machine: a 40-command
monitor, the Road Pops graphical terminal, the Driving Award window manager,
EL0 user programs, networking, and USB keyboard input. What they did **not**
ship is a coherent *interface*:

- The line editor is a fixed buffer — backspace and Ctrl-C, no history, no
  cursor movement, no completion (`kernel/src/lineedit.zig`).
- The input keymap decodes the printable ASCII subset plus Enter/Backspace/Tab
  but not arrow keys or Ctrl-chord editing (`kernel/src/input.zig`).
- `help` is a flat list of one-line blurbs; there is no `help <cmd>`, no
  grouping, no topic pages.
- Error and usage output is ad hoc per handler; a bad invocation may print
  nothing useful, and there is no single `error:`/`usage:` shape.
- Pointer reports are parsed and recorded but never consumed — there is no
  cursor, no click-to-focus, and no rendered indication of which window has
  focus.

This ADR pins the *interface contract* so the milestone-eight cards implement
one coherent, discoverable system rather than N independent features. It is
normative, and it is enforced by gates (see D6), not by prose alone.

## Decisions

### D1. Command grammar and discovery

- Verbs are lowercase and space-separated; sub-verbs extend a verb
  (`net udp listen`, `dui focus`, `usb devices`). The existing positional
  surface stays positional; this ADR does not introduce a flag convention.
- Every command carries two mandatory pieces of metadata:
  1. a one-line blurb (already part of the byte-identical transcript), and
  2. a usage string (`<cmd> <args>`), shown on misuse.
- `help` with no argument prints a **grouped catalog**. The current 40
  commands map onto these groups (the exact mapping is an implementation
  detail of card U1):

  | Group | Examples |
  |-------|----------|
  | machine / identity | `about`, `version`, `uname`, `elephant`, `beans` |
  | memory / machine state | `mem`, `hex`, `pages`, `pci`, `handoff`, `addrspaces`, `fault`, `uaccess`, `timer` |
  | tasks / processes | `tasks`, `spawn`, `exec`, `procs`, `kill`, `mbox`, `syscalls` |
  | storage | `ls`, `cat`, `write`, `mount` |
  | networking | `net`, `netsend` |
  | graphics / input | `screen`, `text`, `roadpops`, `dui`, `input`, `usb` |
  | system | `help`, `echo`, `clear`, `repeat`, `random`, `reboot`, `shutdown` |

- `help <cmd>` prints the usage string plus a few lines of description.
- `help <topic>` opens a topic page (networking, windows, syscalls, storage,
  …). A topic is not a command; it is a named page reachable through `help`.

### D2. Prompt and editing

- The prompt stays `dipshit> `; the banner is printed once at boot.
- The line editor gains, as bounded fixed-BSS behavior:
  - **recall** — up/down walk a bounded history ring (session-scoped);
  - **cursor movement** — left/right, Home, End;
  - **editing chords** — Ctrl-A (start), Ctrl-E (end), Ctrl-K (kill to end),
    Ctrl-U (kill to start), Ctrl-L (clear screen), Ctrl-C (cancel line);
  - **Delete** in addition to Backspace;
  - **tab completion** — completes command names and sub-verbs, bounded, and
    does nothing (or a bell) on ambiguity.
- The existing byte seam is preserved: backspace emits `\b \b`, submit emits
  `\r\n`, cancel emits `^C\r\n`. The transcript gates must keep passing
  byte-identically.
- Modifiers other than shift begin to *matter* here (Ctrl for chords, arrow
  usages for movement); that is an input-path change, not an ADR 0007 change.

### D3. Error and usage contract

Three exact shapes, deterministic, and no handler may panic on bad input:

1. Misuse → `usage: <cmd> <args>` plus a one-line hint, then the prompt.
2. Failure → `error: <actionable message>`.
3. Unknown verb → `unknown command '<x>' — try 'help'`.

- Commands are case-sensitive.
- A command that cannot do what was asked reports *why* (full pool, bad file,
  unresolved peer) in the `error:` shape, never as a bare negative number.
- The misuse and error transcripts are themselves gate-tested (card U3), so a
  new command that prints a fourth shape fails CI.

### D4. Window interface (Driving Award)

- **Focus is always visible.** A rendered title-bar/border treatment marks the
  focused window; focus is never inferable only from memory or a report line.
- **Click = focus + raise** — the topmost window under the pointer takes focus
  and moves to the top of the z-order.
- **Keyboard focus cycling** — one chord (implementation choice: Alt+Tab or a
  Cmd modifier) cycles focus among windows.
- The Road Pops terminal is window 0 and is never closed.
- User windows draw a title bar carrying a name and the owning pid; closing is
  an explicit, visible affordance (already `dui close` / `sys_win_close`).

### D5. Support and first-boot surface

- `about` explains the system in one screen (unchanged in spirit, refreshed).
- `welcome` (alias `tour`) walks a first-time user through a short scripted
  tour: what this is, `help`, one echo round trip, `procs`, and where the docs
  live.
- A boot **motd/status line** summarizes what just booted and what works
  (one line, deterministic).
- `sysinfo` prints the support snapshot in one command: version, machine,
  memory, pages, processes, networking, graphics, and input status. Its stable
  fields are byte-deterministic so a support report is reproducible.

### D6. Enforceability

The guidelines are enforced by gates, not by review:

| Guideline | Gate |
|-----------|------|
| Help catalog + `help <cmd>` + usage strings | class A transcript + live `help` walk (U1) |
| Prompt/editing behavior | live keystroke gate over the I3 input path (U2) |
| Error/usage shapes, no panics | misuse transcript + handler fuzz (U3) |
| Visible focus + click/raise + cycling | pixel + live gate (U4/U5) |
| First-boot + `sysinfo` | transcript (U6/U7) |
| Persistent settings | live persistence across reboot (U8) |

## What this is not

- **Not a visual-design spec.** Colors, spacing, and exact glyphs stay in the
  theme/Driving Award implementation; this ADR fixes *behavior and
  discoverability*, not pixels.
- **Not POSIX / readline / GNU coreutils compatibility.** The grammar stays
  DipshitOS's own; there is no promise of shell scripting, pipes, job control,
  or `sh` semantics in this milestone.
- **Not an ADR 0007 change.** No new syscall numbers are implied by this ADR;
  any future syscall (e.g. a focus syscall) lands as its own ADR 0007
  amendment, not here.

## Consequences

- Every new or changed command must ship its blurb, usage string, and
  `help <cmd>` entry, or the help/misuse gates fail.
- The milestone-eight cards (U0–U8) implemented this ADR; their scope, order,
  and agent split lived in `march-m8.md`, condensed into
  [`era-m0-m51.md`](../archive/era-m0-m51.md) (verbatim at its pinned SHA).
- Status and roadmap updates land in `docs/status.md` / `docs/roadmap.md` at
  card close-out, per the repo's coordination rules.
