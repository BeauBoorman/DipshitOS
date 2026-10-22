---
title: Contributing & toolchain
parent: development
status: published
tags: [development, contributing]
---

# Contributing & toolchain

The project's rulebook is
[`AGENTS.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/AGENTS.md)
— read it before changing anything. This page covers the mechanics: making
the toolchain behave, running the gates, and adding a new one. The workflow
side (cards, claims, worktrees, PR etiquette) is [[development]].

One honest prerequisite: VirelaiOS is **source-available, not open
source** — see [[license]]. Contributions land by the owner's review and
under the project's rules, not by default.

## Toolchain sanity, first

Run the environment check at the start of every session:

```bash
source tools/env-check.sh        # or: just check-env
```

The failure it exists to catch is subtle: a fresh shell frequently puts
`/usr/bin` and `/bin` ahead of Homebrew, so `bash` silently resolves to
the 2007-era system bash 3.2 and `sed` to BSD sed — and the gate scripts
misbehave in ways no error message names. The check re-prepends
`/opt/homebrew/bin` (and the keg-only `gnu-sed` gnubin), verifies
`bash`/`sed`/`jq`/`yq` resolve to the modern builds, diffs the
`GOOS=virelai` fork against `tools/go/overlay/` (a stale fork builds
every Go ELF against the wrong runtime), and returns non-zero with a loud
red complaint when anything is off. The fix is
`brew install bash gnu-sed jq yq`, the `PATH` reorder it prints, then
re-source — plus `bash tools/go/apply.sh` if the fork drifted.

The Zig compiler itself is pinned: `.zigversion` says **0.17.0**,
`tools/zig/lock.json` carries the archive URLs and checksums, and
`tools/zig/sdk.py` materializes the SDK into `.build/zig-guest` —
offline-by-default, checksum-verified, and it refuses concurrent
substitution. Gates put the materialized directory first on `PATH`; an
unpinned `zig` elsewhere on your `PATH` must not win (it has broken the
suite before). One known upstream caveat: ZLS does not work with 0.17.0 —
that is not a VirelaiOS bug, so please do not file it.

## Running the gates locally

```bash
just verify-portable   # class A, deterministic — exactly what CI proves
just verify-vz         # class B, boots real VZ VMs — Apple silicon only
just gate <id>         # one fleet member by id or unique prefix
just gates <pattern>   # every member whose id contains the substring
just gate-list         # print the discovered fleet
```

Class A is `zig fmt --check`, the parallel `zig build test` unit suites,
the byte-identical `virelai>` transcript, `zig build` + `image` +
`inspect`, `swift build` + `swift test`, the Go package tests, the context
snapshot, the coordination gate, and the inventory/lint checks — the same
list `just verify-portable` runs, line for line, in the `justfile`.

Class B is different in kind: each gate boots a real
Virtualization.framework VM and asserts on what the kernel reports. CI
cannot run these — zero of them run on GitHub's runners — so on anything
touching hardware behavior your local run is the evidence, recorded under
`artifacts/`. Some class-B specs need the Go fixture fleet first
(`just go-toolchain`); an unprovisioned spec refuses by name rather than
guessing.

## Adding a gate

New verification gates are **declarative specs**, never new scripts. The
format is frozen and documented in
[`tools/gate/SPEC.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/tools/gate/SPEC.md):
a spec *declares* using only the `vgate_*` builtins (`vgate_name`,
`vgate_share`, `vgate_run TAG -- FLAGS...`, `vgate_client`,
`vgate_checkpoint`, and friends), and `tools/gate/vgate.sh` executes it —
anything outside the `vgate_*` vocabulary fails the run. A spec header is
*what + why* in fifteen lines; history and claim numbers live in git and
on issues.

Two standing rules:

- **Extend an existing spec when it already covers the change.** One spec
  may assert several things; do not mint a new spec per tiny card.
- **Adding the spec file is the whole registration.** The fleet is
  discovered, not listed — `tools/gate/fleet.sh` picks up every file in
  `tools/gate/specs/` into `verify-vz`, `just gate`, and the CI shards
  with zero list edits. The generated `docs/gate-fleet-inventory.md`
  snapshot must *not* ride along in the PR.

What a gate produces is its evidence: `artifacts/NAME-report.txt`,
per-run serial logs and run files, plus any copied receipts — committed
only as small pinned fixtures, never as logs. A spec that dies mid-plan
before its result block reads as a failure, never a pass.

## The no-GPL rule

**No GPL-family code in the system, the build, or this repository, ever.**
Never vendor, copy, port, translate, link, or ship GPL/LGPL/AGPL code in
the guest, the host app, the build, or the repo — and a new dependency,
host tool, or test reference must not be GPL-family either. Record the
license whenever you adopt a third-party input; if no non-GPL alternative
exists, stop and ask the owner.

The single exception is ADR 0058's signed store payload: a GPL-family
program may ship as a signed STORE artifact built in its own *sibling*
repository — source, headers, patches, license text, and binaries all live
there and travel the signed channel, never this repository or the system
image.

## Commits and PRs

Work lands on `agent/<name>/<slug>` branches (one per worktree —
`just new-agent`), never directly on `main`. `main` is protected by a
repository ruleset: pull request required, linear history, and the
required check `Build (macOS + Swift Launcher)` — the class-A set. Before
opening the PR:

```bash
just verify-portable        # the CI surface
just verify-coordination    # your Touches don't overlap another active claim
just gate <relevant-ids>    # class-B evidence for hardware-adjacent changes
```

Say `Closes #<your claim issue>` exactly once in the landing PR — merge
then closes the claim automatically, and nowhere else (the auto-close
footgun is real; see [[development]]). Post the evidence comment, link the
PR, and stop watching: the class-B results in your comment are the
evidence, not CI.

<Aside kind="info">

**CLAIM / EVIDENCE.** If a toolchain or site-compiler input misbehaves,
file a narrowly-scoped issue with reproduction evidence — do not patch
around it silently in the consumer. The same rule applies to the pinned
Boris site toolchain (one revision, `.github/boris-pin.json`): bumping it
is its own small ritual with gate evidence, not a drive-by edit.

</Aside>
