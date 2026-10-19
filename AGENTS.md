# AGENTS.md — rules for working in this repository

These rules bind any AI agent or human contributor working in this project.

## Standing Authority

You are authorized to act without asking on:

- **Missing toolchain / worktree / build files.** If a prepared fork, worktree,
  or build artifact is absent, rebuild it from stock sources and report what you
  rebuilt. Rebuilding the *same* fixture from scratch is expected, not a decision.
  Never silently substitute a *different* fixture or toolchain and present its
  results as the original's.
- **Environment recovery.** Re-clone, re-fetch, re-install anything the task needs
  that isn't present. The task description is the authority; a missing file is
  not a question.
- **Routine git operations.** Branch, commit, push to the session branch, open PRs.
  Never merge without the owner's review.

Ask the owner only when:

- Recovery requires choosing between *different* approaches with different
  correctness implications (e.g. substituting a different Go version for a
  pinned one).
- Credentials, payments, or external accounts are involved.
- The action is irreversible or destructive (deleting data, force-pushing,
  closing issues/PRs).

## Project identity

- This is a from-scratch AArch64 operating system project.
- It runs on Apple silicon running macOS 27 or newer, hosted by Apple's
  Virtualization.framework. It is **not Linux, not Unix, and not QEMU**:
  no emulator, no libc, no POSIX, and no existing guest OS anywhere in the
  boot path.
- It must not depend on libc, POSIX, or an existing guest operating system.
- The guest implementation language is Zig; the host launcher is Swift.

## Where we are

Read **`docs/status.md`** — the canonical status table (milestones, active
work, next). Do not duplicate status prose here, in `march-*.md`, or in a
scoping doc. Canonical answer lives in one place.

## Scope rules

- Do not implement work from later milestones.
- Do not introduce libc or POSIX.
- Do not change the boot default unless the card is explicitly about doing so.
- **No GPL-family code in the system, the build, or this repository, ever.**
  Never vendor, copy, port, translate, link or ship GPL, LGPL or AGPL code
  in the guest system, the host app, the build or this repository. A new
  dependency, host tool or test reference must not be GPL-family either; if
  no alternative exists, stop and ask the owner. Record the license whenever
  you adopt a third-party input.
  - The one exception is a GPL-family program shipped as a signed store
    payload built in its own sibling repository and installed through STORE
    (ADR 0058): everything GPL — source, headers, patches, license text,
    binaries — lives in that sibling repo and travels the signed channel,
    never this repository, the system image, or the build.

## Evidence rules

- State what was **observed** versus **inferred**. Never present a guess as a
  result, and never fabricate command output.
- **Gates are the evidence.** Run the relevant gates; their output lives in
  CI and the local, gitignored `artifacts/`. Commit only small pinned
  fixtures (a golden file, a byte vector), not logs or narrative write-ups.
- If a dependency or platform capability is unavailable, finish everything
  else and name the precise blocked step.

## Documentation — keep it thin

- **One doc per arc, not four.** Write an **ADR** (`docs/decisions/`) only
  when the decision is ABI/security/cross-cutting or expensive to reverse.
  The ADR carries the card split and acceptance; do not also write a
  separate `*-scoping.md` unless the arc is genuinely multi-week.
- **`docs/march-m*.md` is retired for new work.** Existing trackers stay as
  history; cards + `docs/status.md` cover new milestones. Do not add one.
- **`docs/status.md` is a compact table, not a changelog.** Rows are
  `milestone | state | one line | links`. Per-card detail lives on the GitHub
  issue. When you complete something, edit its row (or add one small line),
  not a paragraph.
- Record hardware assumptions in `docs/hardware-contract.md`; keep
  `README.md` and `docs/testing.md` honest about what was observed.

## Gate rules (permanent)

- New verification gates are declarative specs under `tools/gate/specs/`
  (`tools/gate/SPEC.md` format) — never a new `tools/verify-*.sh` script.
- **Extend an existing spec when it already covers the change**; do not add a
  new spec per tiny card. One spec may assert several things.
- The fleet is discovered, not listed (`tools/gate/fleet.sh`). The generated
  `docs/gate-fleet-inventory.md` is a snapshot: exempt from the coordination
  gate, and **must not appear in a spec or script PR**. Adding a spec
  registers it; do not re-render and commit the inventory. `--check` enforces
  spec-order and locale invariance, not byte-equality with the snapshot.

## Host toolchain sanity check (source me first)

This repo's build + gate scripts assume the **modern Homebrew builds** of the
Unix toolchain. macOS still ships 2007-era GNU bash 3.2 under `/bin/bash` and
BSD sed under `/usr/bin/sed`; non-interactive agents frequently get PATH with
`/usr/bin`/`/bin` in front of `/opt/homebrew/bin`, so `bash`/`sed` silently
resolve to the old system versions and the gates misbehave in confusing ways.

**Before starting any work in a fresh session, run:**

```bash
source tools/env-check.sh        # or: just check-env; or: bash tools/env-check.sh
```

It ensures `$HOMEBREW_BIN` leads PATH, verifies the resolved `bash`/`sed`/
`jq`/`yq` are the modern builds, and prints a very loud red complaint (returning
non-zero) when the system versions win. Fix with
`brew install bash gnu-sed jq yq &&` fix PATH, then re-source. Safe and
idempotent — run it from your login/agent startup once per session.

## Agent harness discipline

The issue tracker is cross-session handoff, not a live feed. Time spent
filing, polling, or narrating on GitHub is time not spent on the card.

- **No micro-issues.** A card is a landable unit: scoped deliverable +
  verification. Split a card only when each shard is independently claimable
  by a different agent with disjoint `Touches` (the M63/M65 pattern).
  Anything you notice while holding a card that fits inside its `Touches`
  and its verification bar goes into that card as a fixup commit — not a
  new issue. Filing an issue costs every other agent a coordination read;
  a sub-day fix in files you already touch never earns one.
- **Never file an issue for work you are about to do in the same session.**
  Claim or code. If it cannot be claimed (no landable scope, no
  verification), it is a todo in your own task list, not a tracker entry.
- **After `gh pr create`: stop watching.** Post the evidence comment, link
  the PR, and return to code. Do not poll `gh pr checks`, do not watch
  Actions, do not loop `sleep` + `gh` waiting for lights: 0 class-B gates
  run in CI (see `docs/status.md`) — your local gate runs are the evidence,
  and the reference-host runs happen without you. One status read when you
  resume next session is the entire budget.
- **Incorporate feedback by coding.** When review comments arrive, answer
  with commits on the branch, not comment threads. A reply without code is
  owed only when the feedback is rejected — and then it states the
  technical reason once, not a negotiation.
- **Never write a closing keyword next to an issue number unless you mean
  it.** GitHub auto-closes on `close`/`fix`/`resolve #N` and does **not**
  honour negation — "this PR does not close #N" closes #N (observed
  2026-09-20: #1547's body closed #1543 one second after merge). To leave
  a card open, write "leaves #N open". `Closes #N` appears exactly once:
  in the landing PR of the claimed card, nowhere else.
- **Heartbeats are for days, not minutes.** Append progress comments when
  the state actually changes across sessions, not as a liveblog of a
  single session. Nobody's gate reads your narration; everybody's gate
  reads your `Touches`.

## Multiagent coordination rules

Multiple agents and humans develop this repo in parallel. Claims are GitHub
issues — **no coordination files live in the repository**. The binding rules:

- **One worktree per agent.** Concurrent agents never share a checkout. Create
  yours with `just new-agent <name> <slug>` (worktree at `../virelaios-<name>`,
  branch `agent/<name>/<slug>` off `origin/main`), reattach with
  `just resume-agent`, clean up with `just drop-agent`. Each worktree has its
  own `.build/` and `artifacts/`, so builds and class-B VM gates cannot collide.
- **One issue per card, and the card IS the claim.** When you start an existing
  card, claim it in place: `just claim-card <issue>` (adds the `claim` label and
  the machine-read `Owner`/`Scope`/`Touches` fields) — do **not** file a second
  issue. Ad-hoc work with no card may file one with `bash tools/status/new-claim.sh`
  (flags in its header). The landing PR must say `Closes #<the claimed issue>` so
  merge closes it automatically — never leave a claim open after merge.
- **The machine-read fields** (the coordination gate parses them): an `Owner`
  bullet naming the agent and its backticked branch, a comma-separated `Touches`
  bullet of every path/glob you will edit, and an optional `Status: ⛔` when
  blocked. An OPEN `claim` issue is an ACTIVE claim — another agent will not
  duplicate it.
- **One editor per file at a time.** The gate fails when two ACTIVE claims from
  different branches declare overlapping `Touches`. Generated artifacts
  (`docs/gate-fleet-inventory.md`) are exempt and must not be in the PR.
- **Progress and completion live on the issue.** Append progress as comments
  (never rewrite earlier comments); close with a final evidence comment. Blocked
  = comment and set `Status: ⛔` (or close).
- **Heartbeats.** A `claim` issue with no update for 14+ days draws a gate
  warning; a weekly sweep (`.github/workflows/claim-staleness.yml`) also labels
  it `claim:stale` (filter `--label claim --label claim:stale`), and the label
  clears on the next human comment/edit/reopen. Past ~21 days anyone may close
  it.
- **The gate.** Run `bash tools/status/verify-issue-coordination.sh`
  (`just verify-coordination`, also CI) before opening a PR. It reads open
  `claim` issues via `gh` (GH_TOKEN in CI), fails on `Touches` overlaps between
  branches, and warns on stale claims. `bash tools/status/test-coordination.sh`
  (`just test-coordination`) tests the tooling offline.
