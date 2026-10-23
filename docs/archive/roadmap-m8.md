# Roadmap archive — Milestone eight — usability: human interface

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).

---

## Milestone eight — usability: human interface (HIG + shell/window/support)

> **Scope (2026-08-14).** Milestones zero through seven shipped a complete
> machine; milestone eight turns it into a *usable* one. The normative
> contract is **ADR 0008**
> ([`docs/decisions/0008-human-interface-guidelines.md`](../decisions/0008-human-interface-guidelines.md)):
> one command grammar + grouped `help`, a real line editor (history, cursor
> movement, Ctrl chords, tab completion), one `error:`/`usage:` shape, a
> visible-focus window model with click-to-focus, and an `about`/`welcome`/
> `sysinfo` support surface — all enforced by gates, not prose. Per-card
> tracker + collision-free agent split:
> [`docs/march-m8.md`](march-m8.md). The cards, in order:

- **U0 — Human interface guidelines (ADR 0008).** ✅ **DONE 2026-08-14
  (claim 8938).** The normative shell/window/support contract (D1 command
  grammar + grouped help, D2 prompt/editing, D3 error/usage shapes, D4 window
  interface, D5 support surface, D6 gate-enforceability). Docs only — no code,
  no ADR 0007 change, no POSIX/readline promise.
- **U1 — Help & catalog.** ✅ **DONE 2026-08-14 (claim 3275).** grouped
  `help` + `help <cmd>` + `help <topic>` pages, usage strings wired to
  handlers (they already were — U1 adds the category field + the grouped
  catalog + `topic_body`). Topics: networking, windows, storage, graphics;
  command-named topics (`syscalls`, `input`) resolve to their command detail.
  Gate: the byte-identical transcript (regenerated) + the live `help` walk
  `tools/verify-live-help.sh` PASS 1/1 on VZ.
- **U2 — Shell editing & history.** ✅ **DONE 2026-08-14 (claim 1809).**
  bounded history ring, cursor left/right + Home/End, Ctrl-A/E/K/U/L/C,
  Delete, and tab completion over the I3 input path; the arrow/Home/End/
  Delete usages + Ctrl-chord modifier decoding landed in `input.zig`; the
  runner gained `--input-chords` (one NSEvent per keyDown/keyUp). Gate:
  `tools/verify-live-editing.sh` PASS 1/1 on VZ (mid-line insert + Up recall
  typed by a real keyboard); the unchanged paths stay byte-identical. Also
  fixed a latent I3 interrupt-ring wrap OOB (`xhci.zig`) the longer sequence
  exposed (phantom-key re-read).
- **U3 — Error/usage contract.** ✅ **DONE 2026-08-14 (claim 1511).** one
  `usage: <cmd> <args>` (registry single usage string, reused for sub-verb
  misuse via `print_usage`), one `error: <actionable>` (`err_prefix`) across
  storage/machine/win/kill/netsend/screen/text/exec + the whole net family,
  one `unknown command '<x>' -- try 'help'`; byte-exact misuse transcript
  (`usage: pages [selftest]`, `error: …`, the long-line unknown verb) + three
  deterministic host fuzz tests (tokenizer / handlers / full input path) that
  never panic. The fuzz found and the card fixed a latent U2 width bug: the
  history ring's `@min(hist_count, hist_capacity - 1)` inferred **u4** and
  overflowed at the 16th distinct history entry (explicit `usize` anchor +
  regression test). Live help + live transcript gates re-run green.
- **U4 — Pointer focus + cursor.** ⛔ blocked at the live seam (claim
  4993; kernel + runner landed and host-tested — five pointer synthesis
  routes produced zero guest reports, hardware contract; the real-mouse
  + Accessibility follow-ups recorded).
- **U5 — Window HIG.** ✅ **DONE 2026-08-14 (claim 0935).** title bars
  (name + owning pid) on user windows, a white 3-px focus ring on the
  focused window (focus changes repaint the scene), click = focus + raise
  (topmost hit-test), and keyboard focus cycling (`cycle_focus` + the `dui
  cycle` command; the Alt+Tab HID decode is host-tested). Gate:
  `tools/verify-live-win-hig.sh` PASS 8/8 on VZ — scale-aware pixel proof:
  the ring on the focused window, the terminal edge NOT ringed, the user
  window's title-bar strip.
- **U6 — First-boot experience.** ⬜ `welcome`/`about` refresh + boot motd.
- **U7 — `sysinfo`.** ⬜ the one-command support snapshot.
- **U8 — Persistent settings.** ⬜ `settings get/set` backed by a DATA-partition
  config file, read at boot.

**Non-goals (for now):** POSIX/readline/coreutils compatibility, shell
scripting/pipes/job control, any syscall-number addition (a focus syscall, if
ever, lands as its own ADR 0007 amendment), and a visual-design pixel spec
(colors/spacing stay implementation detail).
