---
title: Deterministic checks
parent: evidence
status: published
tags: [evidence, class-a, ci]
---

# Deterministic checks (class A)

Class A is the portable, deterministic set: no Apple silicon, no VM, no
timing dependence. It is exactly what GitHub CI proves on every push and
pull request, and `just verify-portable` runs the same recipe locally —
`tools/lint-workflows.sh` even asserts that every command in the recipe
appears in `.github/workflows/ci.yml`, so a portable check cannot silently
go local-only.

## What it runs

```bash
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
bash tools/verify-unit-tests.sh
zig build test-console
zig build
zig build image
zig build inspect
swift build --package-path host/vm-runner
swift test --package-path host/vm-runner
go -C user/go test ./...
go -C tools/go/vlfs test ./...
zig build context
bash tools/status/verify-issue-coordination.sh
bash tools/status/test-coordination.sh
bash tools/inventory-gates.sh --check
bash tools/lint-workflows.sh
bash tools/verify-mmu-debt.sh
bash tools/verify-glyph-raster.sh
bash tools/verify-ttf-fonts.sh
bash tools/verify-mutations.sh
bash tools/verify-bss-budget.sh
bash tools/verify-vf-class-a.sh
bash tools/gate/test-gate-run.sh
python3 tools/gate/bench-check.py
bash tools/go/test-ensure-guest-elf.sh
```

## What each check pins

- **`zig fmt --check`** — formatting is part of the contract, not a suggestion.
- **`verify-unit-tests.sh`** — the Zig unit suite (thousands of host tests)
  for the pure logic: allocators, ARP/IPv4/UDP/TCP checksums and state
  machines, the text renderer against a mock canvas, the window compositor,
  syscall dispatch, the crash-state enumerators, and more. M41 de-monolithized
  the sources so these run in parallel.
- **`zig build test-console`** — a **byte-identical** mock transcript
  fixture: the monitor must produce exactly the expected output, so a stray
  character in the banner or prompt fails deterministically.
- **build / image / inspect** — the EFI binary, the GPT+FAT32 boot image,
  and the inspection stages.
- **`swift build` + `swift test` on `host/vm-runner`** — the Swift host
  launcher builds clean and its own suite (the serial parser, the runner's
  scripted-input machinery) passes.
- **`go -C user/go test` / `go -C tools/go/vlfs test`** — the Go SDK's
  class-A loop: the pure layers of the userland modules plus the host-side
  VLFS tooling (`mkfs.vlfs`, the journal checker) that the class-B specs
  consume.
- **`zig build context`** — the context snapshot stage.
- **`verify-issue-coordination.sh` + `test-coordination.sh`** — the
  [[claims|coordination gate]] and its offline test harness: open `claim`
  issues are fetched via `gh` and two claims from different branches
  declaring overlapping `Touches` fail the build.
- **`inventory-gates.sh --check`** — the class-B fleet is discovered, not
  listed: this enforces spec-order, locale invariance, and the spec-shape
  guards (the `exec`-ordering and warm-census declaration parsers), not
  byte-equality with the generated snapshot.
- **`lint-workflows.sh`** — a pinned actionlint over `.github/workflows/`:
  trigger/expression typos fail in CI instead of surfacing only when a
  workflow runs for real; it also keeps `verify-portable` and the CI
  workflow in lockstep. It self-bootstraps actionlint into `.build/` when
  it is not on PATH.
- **budget, raster, and font pins** — `verify-bss-budget`,
  `verify-glyph-raster`, `verify-ttf-fonts`, `verify-mutations`, and
  `verify-vf-class-a` hold the measured bounds: the BSS budget, the
  mirror-tripwire glyph decoder (it renders the clock window forward,
  mirrors each glyph in-cell, and asserts the tripwire fires — all
  offline), the TrueType corpus, and the host-file channel's class-A seam.
- **`verify-mmu-debt.sh`** — the ADR 0006 MMU contract (T0SZ=16 + the TLBI
  comments) stays enforced.
- **`bench-check.py`** — the [[benchmarks|bench]] tables' class-A half:
  parses `corpus.tsv`/`budgets.tsv`, enforces the join both ways (no orphan
  budget, no unbudgeted leg), verifies `budget = baseline × margin`
  arithmetic, and self-tests against fixtures. An unenforced measurement
  cannot ship.
- **`test-gate-run.sh` + `test-ensure-guest-elf.sh`** — the harness tests
  itself: the per-run isolation wrapper and the Go-fixture staging path
  have their own class-A coverage.

<Aside kind="info">

**VERIFIED.** Class A runs on the repository's CI on every push. It is the
fast, deterministic floor — and it is *not* hardware evidence. For what the
firmware-gated half looks like, see [[live-gates]].

</Aside>
