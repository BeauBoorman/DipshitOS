---
title: Contributing & toolchain
parent: development
status: published
tags: [development, contributing]
---

# Contributing & toolchain

The project's rulebook is `AGENTS.md` — read it first. This page is the
short version.

## Toolchain pins

| Tool | Pin |
|------|-----|
| Zig | 0.17.0 (`.zigversion`) |
| Host Swift | macOS 27 SDK (Virtualization.framework) |
| Python | 3 (disk-image tooling, stdlib only) |
| Shell | bash (gate scripts) |
| Boris (site compiler) | one revision, pinned in `.github/boris-pin.json` |

## The claims ceremony

Work lands as a **claim**:

1. File one GitHub issue labeled `claim` — for ad-hoc work run
   `bash tools/status/new-claim.sh`, for a carded unit `just claim-card <issue>` —
   with the owner branch and the files it will touch in the body.
2. Implement on a branch, with host tests.
3. Where hardware is involved, add a class B gate and save evidence under
   `artifacts/`.
4. Comment progress on the claim issue; close it (with an evidence
   comment) when the work lands. Run
   `bash tools/status/verify-issue-coordination.sh` before opening a PR.

The ceremony is not optional — it is how the project keeps "observed" honest.

## What a PR must pass

- **Class A** on CI (deterministic — the `verify-portable` set).
- **Class B** on Apple silicon, for anything touching hardware behavior
  (CI cannot run these; the PR documents the run).
- The coordination gate (open `claim` issues don't declare overlapping
  file touches — read from the GitHub tracker via `gh`).
- For site changes: the **docs gate** (`boris validate`) — broken links,
  escaping URLs, or a failing theme contract block the merge.

## One-way toolchain boundary

Boris compiles this site; VirelaiOS does not own Boris. The revision is pinned
once (`.github/boris-pin.json`) and shared by the docs gate and the Pages
workflow. Updating it is a ritual: bump the pin → build → validate → compile
with the project-site flags → run the gates → commit the bump with evidence.

<Aside kind="info">

**CLAIM / EVIDENCE.** If Boris itself misbehaves while this site is a
consumer, the project files a narrowly-scoped upstream issue with
reproduction evidence — it does not crawl into Boris source to fix it from
the consumer side.

</Aside>
