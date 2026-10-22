---
title: Evidence & testing
status: published
tags: [evidence, testing]
---

# Evidence & testing

VirelaiOS has unusually serious verification machinery for a hobby OS, and it
exists for one reason: **a feature is only "observed" when a matching gate
passes.** No evidence, no claim. This page is the map of that machinery —
what the classes are, how the fleet is discovered, and which guardrails keep
the documentation itself honest.

## The honest vocabulary

Three words carry the whole system:

| Term | Meaning |
|------|---------|
| **observed** | a gate ran and passed; the log or capture exists under `artifacts/` (gitignored — evidence is local, never committed) or in a recorded CI/tracker run |
| **inferred** | reasoned about or documented, but not yet observed on hardware |
| **claim** | a filed unit of work — a GitHub issue labeled `claim` — with an owner, a scope, and a gate |

A fourth word, **gate**, is the instrument: a declarative spec under
`tools/gate/specs/`, run by `just gate <id>`, that exits 0 only when the
asserted evidence was produced. The distinction matters everywhere on this
site: when a page says a behavior is live-gated, that is a pointer to a named
gate you can re-run — not marketing. Hardware assumptions carry the same
discipline: [`docs/hardware-contract.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/hardware-contract.md)
marks every fact `[observed]` or `[inferred]`, and a tag only flips when a
matching probe or serial log lands.

## The gate classes

| Class | What it is | Where it runs |
|-------|------------|---------------|
| **A** — deterministic | formatting, unit tests, a byte-identical console transcript, the build/image pipeline | GitHub CI, every push/PR |
| **B** — live-gated | boots a real Virtualization.framework VM on Apple silicon and asserts on what the kernel reports | the reference host / developer machines — **not** CI |
| **C** — interactive | needs a human at the keyboard (e.g. the real-mouse pointer gate) | a human, by hand |
| **D** — diagnostic | an experiment; passing one proves nothing about a milestone | per claim |

Classes are defined in
[`docs/gate-inventory.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/gate-inventory.md).
The distinction between A and B is the load-bearing one: class A proves code
paths, and class B is the only thing that observes the kernel running under
real firmware.

- [[class-a|Deterministic checks]] — what runs without a VM and why it still counts.
- [[live-gates|Live VZ gates]] — the spec format, the fleet, and the hardware-gated evidence.
- [[benchmarks|Benchmarks]] — performance as a contract: the corpus, the budgets, `live-bench`.
- [[claims|Claims & evidence philosophy]] — how a claim is filed, coordinated, and flipped to observed.

## The fleet is discovered, not listed

Since the M40 gate-fleet consolidation (issue
[#940](https://github.com/drawmeanelephant/VirelaiOS/issues/940)) there is no
hand-maintained gate list anywhere. `tools/gate/fleet.sh` discovers the
class-B fleet from `tools/gate/specs/` — every `*.spec` file, plus four
legacy class-B scripts that predate the spec format (`bad-handoff`, `marker`,
`nvram-console`, `host-console`). At this writing that is **317 members** —
313 specs plus the four scripts; run `bash tools/gate/fleet.sh count` for the
current number, because a hard-coded count would rot on the next spec.

One discovery feeds every consumer with zero list edits: `just gate <id>`,
`just gates <pattern>` (substring match), `just verify-vz` (the whole fleet),
the `.github/workflows/vz-gates.yml` CI shards, and the generated
[`docs/gate-fleet-inventory.md`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/docs/gate-fleet-inventory.md)
snapshot. The inventory is a rendering, not a registry — it is exempt from
the coordination gate precisely because parallel PRs kept colliding on it,
and it must never appear in a spec PR.

<Aside kind="warning">

**LIMITATION.** The fleet is *sharded* in CI (×4) but **zero class-B gates
actually run in CI**: GitHub-hosted runners are not Apple silicon
Virtualization.framework hosts. `vz-gates.yml` is a not-enforced placeholder
until a `VZ_RUNNER_LABEL` runner registers; the reference host and developer
machines run the fleet, and the results land on the tracker. A green CI
badge says exactly "class A passed" — nothing more.

</Aside>

## K-consecutive acceptance

A single green run is a sample; a contract needs repetition. Acceptance
cards conventionally demand **K consecutive green runs** — K=3 for ordinary
journeys, K=5 for the ones that have burned the project before (crash
resilience, toolchain ports, fleet-wide acceptance). `live-vlfs-crash`
carries `vgate_repeat 5 BOOTS`, so every invocation is itself K=5
consecutive kill/remount cycles; other specs take their K from the same
`BOOTS` knob or from the acceptance issue's recorded run table. The
convention is "consecutive" on purpose: a flake that passes on re-run is
recorded, not hidden.

## Evidence on disk

Every run writes under `artifacts/` — serial logs (`NAME-serial-TAG.log`),
runner transcripts, byte-compare captures, scanout PNGs, the bench trend
history — and `artifacts/` is gitignored by design. Evidence is what a host
produced, on that host, at that revision; committing it would pin one
machine's output as everyone's expectation. Small pinned fixtures (a golden
file, a byte vector) are the deliberate exception.

## The docs truth guards

The documentation is held to the same standard as the code. The docs gate
(`.github/workflows/docs-gate.yml`) runs on every push and PR and enforces
three forward-lying checks plus the publication pipeline itself:

1. **Deleted-binary denylist.** The set of `.BIN` names `build.zig` still
   builds is derived mechanically; a binary no longer built may appear on a
   public page only on a line carrying a historical marker
   (`retired`/`deleted`/`now`/`was`/`successor`). `docs/` is exempt —
   ADRs and milestone trackers quote old binaries *as history*.
2. **Stale gate-script names.** `verify-live-*` scripts no longer exist —
   gates are specs run by `just gate <id>` — so naming one as current is a
   forward lie and fails the gate.
3. **The never-lie-forward M-watermark.** No page under `site/`, `docs/`,
   or `README.md` may claim a milestone number higher than the maximum
   `docs/status.md` carries (today: M149). The design choice is deliberate:
   forbid lying *forward*, never enforce freshness — a page that lags the
   ledger is honest, and staleness never reds an unrelated PR.

The same job runs `boris validate` — the pinned
[boris](https://github.com/drawmeanelephant/boris) static-site compiler's
prepublication pass — against `site/` with the exact flags the Pages publish
workflow uses, so broken internal links and asset errors fail before merge.

## Reproducing the checks

```bash
just verify-portable        # class A, mirrors CI
just gate live-vlfs-crash   # one class-B gate
just gates vlfs             # every fleet member matching the pattern
just verify-vz              # the whole class-B fleet, Apple silicon only
```

The aggregate `verify-vz` sweep re-checks the shared seam across every
subsystem in one run — the project's standing regression proof. See
[[live-gates]] for the spec format and [[claims]] for how gate results turn
into ledger entries.

<Aside kind="info">

**VERIFIED.** Everything on this page is mechanical: the class list is
`docs/gate-inventory.md`, the fleet is `tools/gate/fleet.sh`, the truth
guards are inline Python in `docs-gate.yml`. None of it is policy by
convention — it is enforced, and the enforcements are themselves gated.

</Aside>
