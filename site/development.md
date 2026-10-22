---
title: Development
status: published
tags: [development, contributing]
---

# Development

This is how work actually happens in this repository — the card-and-claim
workflow, the evidence bar, and the rules that keep several agents and
humans from colliding on `main`. The binding text is
[`AGENTS.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/AGENTS.md);
this page is the readable version. For the mechanical side — toolchain,
gates, gate authoring — see [[contributing]].

## Cards, claims, and the tracker

Work is planned as **cards**: a milestone has an index issue on GitHub,
and each card is a landable unit with a scoped deliverable and its own
verification bar (the `cards/` directory holds drafts; filed issues are
canonical). When you start a card, you do not file a second issue — **the
card is the claim**. `just claim-card <issue>` adds the `claim` label and
the machine-read fields in place. Only genuinely uncarded work files a new
issue, via `just claim` / `tools/status/new-claim.sh`.

An open `claim` issue is an **active claim** — other agents see it and
stay off your files. The machine-read bullets make that work:

- an **`Owner`** bullet naming the agent and its backticked branch,
- a **`Scope`** and a **`Touches`** bullet — the latter listing every path
  or glob you will edit,
- an optional `Status: ⛔` when the claim is blocked.

`Touches` uses the coordination gate's syntax — exact paths or `dir/*`
prefix globs. The gate strips one trailing `*` and prefix-matches, so
`host/vm-runner/**` does *not* do what a reader expects: it has been
observed to hide a real collision with `host/vm-runner/Package.swift`.
Declare literal paths.

Progress lives on the issue as **appended** comments — earlier comments
are never rewritten — and completion is a final evidence comment. A claim
silent for 14+ days draws a gate warning and a weekly sweep labels it
`claim:stale`; past ~21 days anyone may close it. Heartbeats are for
days, not minutes: nobody's gate reads your narration, everybody's gate
reads your `Touches`.

## One worktree per agent

Concurrent agents never share a checkout. Each works in its own worktree,
created and retired with justfile recipes:

```bash
just new-agent buffy m120-session     # ../virelaios-buffy, branch agent/buffy/m120-session
just resume-agent buffy agent/buffy/m120-session   # reattach an existing branch
just drop-agent buffy                 # remove the worktree when merged
just list-agents                      # every checkout and its branch
```

Each worktree has its own `.build/` and `artifacts/`, so build caches and
live-VM gate output cannot collide. File the claim issue from inside the
worktree, not from the main checkout.

## The coordination gate

Before opening a PR, run `just verify-coordination`
(`tools/status/verify-issue-coordination.sh`). It reads open `claim`
issues through `gh` and fails when two active claims from *different*
branches declare overlapping `Touches` — one editor per file at a time.
It runs in CI too, and `just test-coordination` exercises the tooling
offline. Generated artifacts like `docs/gate-fleet-inventory.md` are
exempt — and must never appear in a spec or script PR.

## The evidence bar

The standing rule: **gates are the evidence**. A claim is *observed* only
when a matching gate's output exists — saved under `artifacts/`
(gitignored) or in CI — and *inferred* is always labeled as inference.
Never fabricate command output; if a dependency is unavailable, finish
everything else and name the precise blocked step. Commit only small
pinned fixtures (a golden file, a byte vector) — never logs or narrative
write-ups. The [[evidence]] page explains the class A/class B split;
[[class-a]] and [[live-gates]] cover each.

Two consequences worth internalizing:

- **Class B cannot run in CI.** Zero live gates run on GitHub's runners;
  your local `just gate <id>` / `just verify-vz` output on Apple silicon
  *is* the evidence, and the reference-host sweep happens without you.
- **The docs gate enforces truth rules on this site.** A retired `.BIN`
  may only be named on a line carrying a marker word
  (`retired`/`deleted`/`now`/`was`/`successor`); `verify-live-*` script
  names are banned outright (gates are `just gate <id>` specs); and no
  page may cite a milestone number higher than `docs/status.md` contains —
  lying *forward* is forbidden, while honest staleness is allowed.

## Landing work

Branch hygiene is `agent/<name>/<slug>` → a PR against `main`. The
landing PR says `Closes #<the claimed issue>` **exactly once**, so merge
closes the claim automatically — and never anywhere else.

<Aside kind="warning">

**VERIFIED.** GitHub auto-closes on `close`/`fix`/`resolve #N` and does
not honor negation — "this PR does not close #N" closes #N anyway
(observed 2026-09-20: one PR body closed a sibling card a second after
merge). To leave a card open, write "leaves #N open".

</Aside>

After `gh pr create`: post the evidence comment, link the PR from the
claim, and **stop watching**. Do not poll checks or loop on Actions —
your local gate runs are the evidence. When review feedback arrives,
answer with commits on the branch; a reply without code is owed only when
feedback is rejected, and then it states the technical reason once. The
required status check is `Build (macOS + Swift Launcher)`; never commit to
`main` directly, and never merge without the owner's review.

A few standing conventions, in AGENTS.md's voice:

- **No micro-issues.** A sub-day fix inside a card's `Touches` goes into
  that card as a fixup commit — not a new tracker entry. Never file an
  issue for work you are about to do in the same session.
- **One doc per arc.** An ADR only when the decision is ABI-, security-,
  or cross-cutting; `docs/status.md` stays a compact table, and the
  `march-m*.md` trackers are retired for new work.
- **No scope creep.** Do not implement later-milestone work, do not
  introduce libc/POSIX, and do not change the boot default unless the card
  is explicitly about doing so.

## The two documentation surfaces

There are deliberately two: this site (`site/`, compiled by Boris into
GitHub Pages) is the public front door, and `docs/` is the engineering
warehouse — ADRs in `docs/decisions/`, the ledger `docs/status.md`, the
testing policy, the hardware contract, archived trackers. The site
promotes and summarizes the warehouse and links to the canonical files;
it never duplicates the ledger. [[layout|The repository map]] shows where
each lives.
