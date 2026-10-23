# docs/archive — era digest, recorded evidence, frozen designs, lore

**Start with [`era-m0-m51.md`](era-m0-m51.md).** The M0–M51 era's
per-milestone record — `march-*.md` trackers, `status-m*-detail.md`
notes, `roadmap-m*.md` plans, one-shot agent prompts, and scoping cards —
is condensed there: one digest line per milestone citing the retired
file names and the commit (`4edfa112`) where their verbatim text last
lived (M189d, issue #3228). History is preserved by reference, not by
file — the same pattern `docs/status.md` uses for its `e5480c9` pointer.

The `claims/` + `logs/` subdirectories that used to live here
(completed claim files and per-branch session logs moved from
`docs/claims/` / `docs/logs/`) were **deleted 2026-09-03** when claims
moved to the GitHub issue tracker (label `claim`) — old claim numbers and
log entries survive only in git history.

What still lives here as files, and why:

- **`ragshit-0176/` and `m3-ragshit-bundle.md`** — point-in-time
  test/audit evidence moved from `artifacts/` (issue #268 / claim 4516);
  raw recorded output, so they carry no banner and must stay
  byte-identical.
- **`dogfood-m27.md`** — the M27 dogfood & completeness sweep report;
  verification evidence.
- **`line-of-sight.md`** — retired board view still cited by
  `tools/verify-zc-corpus.sh`, `tools/build-zc-host.sh`, and ADR 0035.
- **`html-renderer-scoping.md`** — post-era design card (M71i) fixed by
  ADR 0028.
- **`gate-inventory-detail.md`, `hardware-contract-detail.md`** — frozen
  verbatim detail spills of the live `docs/gate-inventory.md` /
  `docs/hardware-contract.md`.
- **`calm-lavoisier-memorial.md`, `dipshitos-name.md`** — project lore.

Everything here is history, not active plans: do not feed these files to
an agent as a work order, and do not treat their milestone expectations
as current state. The canonical, always-current answers are
[`docs/status.md`](../status.md) and [`docs/roadmap.md`](../roadmap.md) —
keep completed-work docs out of `docs/` root so the root holds only
active documentation.

**Stays in `docs/` root:** `wasm-import-contract.md` (the frozen `env.*`
surface — `wasm.zig`, tests, `live-wasm-abi`), `chronicle-prompt.md` (the
current chronicle authoring prompt), the FLINT host-port specs
(`flint-client-spec.md`, `flint-server-spec.md`), and the live operating
docs: `status.md`, `roadmap.md`, `architecture.md`, `testing.md`,
`hardware-contract.md`, `gate-inventory.md`, `TEAMS.md`, `vz-runner.md`,
`ui-primitives.md`, `app-authoring.md`, `diagnostics.md`,
`branch-protection.md`.
