---
title: Claims & evidence philosophy
parent: evidence
status: published
tags: [evidence, claims]
---

# Claims & evidence philosophy

The repository runs on **claims**: a claim is a filed unit of work with a
scope and a gate, and it only flips to observed when the gate passes.
Claims are **GitHub issues labeled `claim`** on the project tracker — they
are not files in the repository (the old `docs/claims/` + `docs/logs/` file
system was deleted 2026-09-03; four-digit claim numbers in old prose are
git-history references).

## The card is the claim

One issue per card. When work begins on an existing milestone card, the
agent claims it **in place** — `just claim-card <issue>` adds the `claim`
label and writes the machine-read fields — rather than filing a second
issue. Only work with no card files a new issue (`bash
tools/status/new-claim.sh`). An OPEN `claim` issue *is* an active claim:
every other agent sees it and will not duplicate the work.

Each agent also gets **one worktree** (`just new-agent <name> <slug>`,
reattach with `just resume-agent`, clean up with `just drop-agent`), so
concurrent claims never share a checkout — each worktree has its own
`.build/` and `artifacts/`, and class-B runs cannot collide.

## The machine-read fields

The claim issue's body carries the fields the coordination gate parses, one
bullet per line:

```
- **Owner:** <agent id> (`<branch>`)      # the backticked branch is required
- **Touches:** path, or dir/prefix* globs # every file the work will edit
- **Status:** ⛔ ...                       # optional; marks the claim blocked
```

`Touches` is the load-bearing field: **one editor per file at a time.** The
coordination gate — `bash tools/status/verify-issue-coordination.sh`, also
`just verify-coordination` and a CI step — reads the open claims via `gh`
and *fails* when two claims from different branches declare overlapping
touches. Generated artifacts (the gate-fleet inventory snapshot) are exempt:
they re-render mechanically and merge sequentially, so declaring one never
holds the file. A `Status: ⛔` claim is excluded from the overlap check —
blocked is not editing.

## Heartbeats and staleness

Progress lives on the issue as appended comments — never rewritten — and a
final evidence comment closes it. A claim with no comment or edit for
**14+ days** draws a gate warning; a weekly sweep
(`.github/workflows/claim-staleness.yml`, `tools/status/sweep-stale-claims.sh`)
comments and applies the `claim:stale` label so stale claims are filterable.
The sweep is bot-aware: its own warning does not reset the clock, and the
event-driven `unlabel-fresh` job removes `claim:stale` the moment *human*
activity lands. Past ~21 days of silence, anyone may close the claim.
Heartbeats are for days, not minutes — no liveblogging a single session.

## Landing and the auto-close footgun

The landing PR says `Closes #<claim>` **exactly once** — in the PR of the
claimed card — so merge closes the issue automatically. GitHub does not
honor negation: writing "does not close #N" still closes #N (observed in the
wild). To leave a card open, write "leaves #N open". And no micro-issues: a
fix that fits inside a claim's `Touches` and verification bar goes in as a
fixup commit on that card, not a new tracker entry — filing an issue costs
every other agent a coordination read.

## How a claim works end to end

1. Claim or file the issue **before** work starts — owner, branch, touches.
2. Land the work on the branch with host tests and, where hardware is
   involved, a [[live-gates|class-B spec]].
3. Save the evidence under `artifacts/` (gitignored — no evidence, no
   "observed") and post it on the issue.
4. `Closes #N` in the landing PR; merge closes the claim.

Open claim issues are the canonical index:
`gh issue list --label claim --state open`. Run `just verify-coordination`
before opening a PR; `just test-coordination` exercises the tooling offline
against fixtures.

## Why this matters to you

When a page here says a feature is **live-gated**, that is a pointer to a
named gate — and usually a named claim — not marketing. You can open the
issue to see the exact scope and honest bounds, run the gate on Apple
silicon to reproduce it, and read the saved evidence for the actual serial
report or capture.

## Observed vs inferred

A hardware fact is `[observed]` only when a matching probe or log exists.
Examples from the hardware contract:

- `[observed]` the entropy device resets at `ExitBootServices`.
- `[observed]` the XHCI controller does not reset there.
- `[observed]` the NAT gateway answers ARP and ICMP but serves no DHCP.

Everything else stays `[inferred]` until proven. The documentation does not
upgrade claims by summarizing them — if it was unit-tested only, the page
says unit-tested only.

<Aside kind="info">

**VERIFIED.** This is the receipt system that lets the public site be a
trustworthy index into the project's actual state rather than vapor — and
it is enforced by the same CI that ships the code.

</Aside>
