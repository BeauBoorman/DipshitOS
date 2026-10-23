# docs/archive — archived one-shot prompts, frozen designs, completed roadmap plans

Files here are one-shot agent prompts, designs, trackers, and roadmap
plans from **completed** milestones (prompts, designs, and the M1.5 march
tracker moved here when their milestone closed; the per-milestone
`roadmap-m{N}.md` plans moved here from `docs/roadmap.md` by issue #264 /
claim 2860). The `claims/` + `logs/` subdirectories that used to live here
(completed claim files and per-branch session logs moved from
`docs/claims/` / `docs/logs/`) were **deleted 2026-09-03** when claims
moved to the GitHub issue tracker (label `claim`) — old claim numbers and
log entries survive only in git history. Completed milestones'
point-in-time test/audit evidence also lives here (`ragshit-0176/`,
`m3-ragshit-bundle.md` — moved from `artifacts/` by issue #268 / claim
4516); the files are raw recorded output, so they carry no banner and must
stay byte-identical.

They are history, not active plans: do not feed them to an agent as a work
order, and do not treat their milestone expectations as current state. The
canonical, always-current answers are [`docs/status.md`](../status.md) and
[`docs/roadmap.md`](../roadmap.md) — keep completed-work docs out of
`docs/` root so the root holds only active documentation.

**M75b (issue #1671, 2026-09-23) moved the closed-arc scoping docs here:**
`wms10-seam-b-scoping.md`, `crypto-scoping.md`,
`desktop-quality-scoping.md`, `wasm-core-scoping.md`,
`roadmap-post-arc5.md`, `agent-concurrency-plan.md`, and
`concurrency-gameplan.md`. Every inbound link (march trackers, roadmap,
TEAMS, wasm-import-contract, line-of-sight, the `syscall.zig` §8 comment)
was rewritten to the `archive/` path in the same change.

**M189b (issue #3226, 2026-10-23) moved the completed-milestone record
here:** every `march-*.md` tracker (M3–M45 plus Arc2),
`m17-desktop-completeness.md`, `dogfood-m27.md`, the
`calm-lavoisier-memorial.md` lore page, the retired `line-of-sight.md`
board view, and the shipped-milestone design cards
`host-file-channel-scoping.md` (M34), `html-renderer-scoping.md` (M71i /
ADR 0028), `ssh-scoping.md` (M51) and `trust-scoping.md` (M50). M1.5's
tracker already lived here as `march-m15.md`, so M15's audio tracker is
`march-m15-audio.md`. Every inbound link (roadmap, ADRs
0007/0008/0013/0024/0025/0028/0035, `status.md` prose,
`tools/context/build-context.sh`, `tools/build-zc-host.sh`,
`tools/verify-zc-corpus.sh`, `tests/zc-corpus/s3-break.z`, `kernel/src/pipe.zig`,
`user/go/gotabwm/tabs.go`, `user/src/tabwm.zig`) was rewritten in the same
change.

**Stays in `docs/` root:** `wasm-import-contract.md` (the frozen `env.*`
surface — `wasm.zig`, tests, `live-wasm-abi`), `chronicle-prompt.md` (the
current chronicle authoring prompt), the FLINT host-port specs
(`flint-client-spec.md`, `flint-server-spec.md`), and the live operating
docs: `status.md`, `roadmap.md`, `architecture.md`, `testing.md`,
`hardware-contract.md`, `gate-inventory.md`, `TEAMS.md`, `vz-runner.md`,
`ui-primitives.md`, `app-authoring.md`, `diagnostics.md`,
`branch-protection.md`.
