# Milestone eight march — usability + human interface (living tracker)

## Where we are

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-eight's per-card detail and collision-free agent split, following
> the [`march-m6.md`](march-m6.md) / [`march-m7.md`](march-m7.md) pattern.
> A card's row flips to ✅ only with real observed evidence, never
> code-complete alone.

Milestones zero through seven shipped a complete machine — but the *interface*
is spartan: a fixed-buffer line editor (backspace + Ctrl-C), a flat `help`
list, ad hoc error output, a parsed-but-unconsumed pointer, and no support or
settings surface. Milestone eight turns "a complete machine" into "a usable
one". The normative contract is **ADR 0008**
([`decisions/0008-human-interface-guidelines.md`](decisions/0008-human-interface-guidelines.md)):
one command grammar, one prompt/editing model, one `error:`/`usage:` shape, a
visible-focus window model, and a support surface — all enforced by gates, not
prose. The cards, in order:

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| U0 | **Human interface guidelines (ADR 0008).** Write the normative shell/window/support contract: command grammar + grouped `help`, prompt/editing behavior, the `error:`/`usage:`/`unknown command` shapes, the Driving Award visible-focus + click/raise/cycling model, the `about`/`welcome`/`motd`/`sysinfo` support surface, and the enforceability table (which gate enforces which guideline). Docs only — no code. | ✅ done (this commit) | `docs/decisions/0008-human-interface-guidelines.md` — accepted 2026-08-14. | Gate: the ADR exists and pins D1–D6; the U1–U8 gates enforce it. The ADR explicitly is NOT an ADR 0007 change (no syscall numbers) and NOT a POSIX/readline promise. |
| U1 | **Help & catalog.** `help` groups the 40 commands by category (machine/memory/tasks/storage/networking/graphics-input/system per D1); `help <cmd>` prints usage + a few lines; `help <topic>` opens a topic page (networking, windows, storage, graphics). Every command's usage string is wired to its handler and shown on misuse. | ✅ done (claim 3275) | `kernel/src/monitor.zig` (`Category` + `topic_body` + grouped `cmd_help`); transcript fixture regenerated; live gate `tools/verify-live-help.sh` | Gate: class A — the grouped catalog + `help <cmd>` rows are part of the byte-identical transcript; plus the live `help` walk `tools/verify-live-help.sh` PASS 1/1 on VZ. Topics that collide with commands (`syscalls`, `input`) resolve to the command detail, not a shadowed topic. Depends on U0. |
| U2 | **Shell editing & history.** Extend `kernel/src/input.zig` (arrow usages, Ctrl-chord modifier handling, Delete) and `kernel/src/lineedit.zig` (bounded history ring, cursor left/right + Home/End, Ctrl-A/E/K/U/L, Ctrl-C, Delete, bounded tab completion of verbs + sub-verbs). Preserve the byte seam: `\b \b` erase, `\r\n` submit, `^C\r\n` cancel. | ✅ done (claim 6233) | `tools/verify-live-lineedit.sh` PASS 13/13 on VZ; class-A transcript byte-identical | Gate: live keystrokes drive recall + editing end to end — the USB keyboard session proves submit/recall/Home+delete-sweep/Left+delete (atomic output-line assertions); the Ctrl chords and Tab completion are proven over the serial byte path (synthesized USB modifiers never reach VZ's HID report — observed three ways, recorded in the hardware contract). Depends on U0 (and I3's input path). Scope additions at claim time: `text.zig` interprets the editing bytes as cursor motion (`\b`, `\r`, `ESC[2J`/`ESC[H`) — the on-screen half of D2, host-tested; the runner seam gained `<up>..<tab>` tokens + `^a`..`^z` chords + `--input-string-interval`. |
| U3 | **Error/usage contract.** One `usage: <cmd> <args>` + hint on misuse, `error: <actionable>` on failure, `unknown command '<x>' — try 'help'` on a bad verb; no handler panics on any bad input. Fuzz the tokenizer and the handlers for the refusal paths. | ✅ done (claim 5001) | class A: the misuse transcript (byte-exact, regenerated) + the fuzz tests (monitor/tokenizer) | Gate: class A misuse transcript (each shape asserted byte-exact) + a host fuzz of the tokenizer/handlers that must never panic. Both landed: the shell transcript gained the D3 misuse section (unknown verb, arity usage+hint, handler refusal, too-many line — each byte-exact) and the fuzz drives 512 garbage lines through the tokenizer plus every handler with garbage argv (no panic; refusal output shape-checked for 16 side-effect-free commands; garbage verbs all take the unknown-command shape, case-sensitivity pinned). The 40 handlers' failure prints migrated onto the D3 helpers (`error:`-prefixed refusals; usage+blurb hints); honest STATUS reports (ls/net/screen/usb device reports, kill-armed) intentionally keep their report lines. Depends on U0; this is the mechanical enforcement of D3. |
| U4 | **Pointer focus + cursor.** Consume the absolute pointer reports (port 10) into Driving Award: hit-test → focus + raise, and draw a cursor at the pointer position. Rendering focus is D4's visible-focus requirement. | ⬜ not started | — | Gate: live pointer events move focus between windows + pixel proof the focus indicator/cursor moves. **Claim-time dependency:** VZ has no programmatic pointer API, so the runner needs a pointer-synthesis seam mirroring `--input-key`/`--input-string` (the I3 keyboard seam's analogue). Depends on U0 + U5's indicator work. |
| U5 | **Window HIG.** Driving Award draws a title bar (name + owning pid) on user windows and a focus ring/border treatment on the focused window; click = focus + raise (topmost hit-test); one keyboard chord cycles focus; the terminal is window 0 and never closes; close stays an explicit affordance. | ⬜ not started | — | Gate: live + pixel — the decoded capture shows the focus treatment on the focused window and it moves when focus changes (a marker-driven capture like the hide/show gate). Depends on U0; pairs with U4. |
| U6 | **First-boot experience.** `welcome` (alias `tour`) walks a scripted tour; `about` is refreshed to explain the system in one screen; a boot motd/status line summarizes what booted and what works (deterministic). | ⬜ not started | — | Gate: transcript — the tour's echo/prompt/reply lines and the motd line are asserted; the boot banner stays byte-identical. Depends on U0. |
| U7 | **`sysinfo`.** One command prints the support snapshot: version, machine, memory, pages, processes, networking, graphics, input status. Stable fields byte-deterministic so a support report is reproducible. | ⬜ not started | — | Gate: transcript — the stable fields are asserted byte-exact; session-dynamic counters are asserted as present. Depends on U0. |
| U8 | **Persistent settings.** A small `settings` surface (`settings get/set <key> <value>`) backed by a config file on the DATA partition (the live-gfs pattern): hostname, theme accent, prompt string, scrollback size. Read at boot, persists across reboot. | ⬜ not started | — | Gate: live persistence across reboot (the `verify-live-gfs` pattern) — a `set` survives a real reboot and is read back at the next boot. Depends on U0. |

## Agent split / collision rules

- **U0** (claim `docs/decisions/0008-human-interface-guidelines.md`, ✅ done):
  owns the ADR text only. No code, no other doc edits beyond this tracker.
- **U1** (future claim): owns `kernel/src/monitor.zig`'s help/registry
  metadata (blurbs, usage strings, the category map), the `help` command's
  grouped/detail/topic paths, and the U1 gate. It claims the help *surface*;
  it must not touch the command *handlers*' behavior.
- **U2** (future claim): owns `kernel/src/lineedit.zig` and the editing half of
  `kernel/src/input.zig` (arrow usages, Ctrl-chord modifier handling, Delete),
  plus the runner's editing-key seam. It claims only what U1 leaves alone; the
  two are disjoint files except a shared input.zig seam, which U2 coordinates
  with the I3 owner.
- **U3** (future claim): owns the error/usage formatting helpers and the
  misuse transcript + handler fuzz. It touches every handler's *reporting*
  (via the shared helpers), so it claims **after** U1's help metadata and
  before any new command lands — this is the contract-fixing card.
- **U4 + U5** (future claims, one owner preferred): own
  `kernel/src/driving_award.zig` (focus ring, title bars, hit-test focus/raise,
  cursor rendering) and the runner's pointer-synthesis seam. They claim only
  after U0 and are the highest-risk cards (a new host input seam + pixel
  proof); one agent should hold both to avoid editing the same compositor.
- **U6 / U7** (future claims, independent): own `about`/`welcome`/motd and
  `sysinfo` respectively; they share `kernel/src/monitor.zig` registration, so
  they are claimed one at a time or by one agent.
- **U8** (future claim): owns the `settings` command + the DATA-partition
  config reader/writer; touches `fat.zig`'s write path only through the
  existing public calls.
- Cross-cutting docs (`status.md`, `roadmap.md`, `gate-inventory.md`) are
  updated per card at claim close-out, never during implementation. New gates
  register in `gate-inventory.md` and `justfile` at their card's close-out.

## Docs follow-ons (outside the card ladder)

- ✅ **DONE 2026-08-14** — the license is posted clearly on the public site +
  README: **source-available, not open source**, stated plainly (a dedicated
  `site/license.md` page + the primary-nav "License" link + an unambiguous
  README license section), not implied by proximity to an open-source badge.
