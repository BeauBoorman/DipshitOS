# Log — milestone eight card U3: error/usage contract (zcode)

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-14** — **Claim (zcode, `agent/zcode/m8-u3-errors`):** claimed
  the milestone-eight card U3 row (the error/usage contract — ADR 0008 D3,
  the mechanical enforcement). Claim file:
  `docs/claims/5001-u3-error-usage-contract.md`. Scope per the march-m8
  agent split: the shared error/usage helpers + every handler's reporting
  migration + the misuse transcript (regenerated, U1 precedent) + the
  deterministic no-panic host fuzz. Branched from the U2 branch (cards
  serialize: U3 claims after U1's help metadata). Shape decisions recorded
  in the claim: empty verb → the unknown-verb shape; tokenizer-level
  too-many/unbalanced-quote → `error:` lines. 🔄 in progress — no code
  written yet.
- **2026-08-14** — **Card U3 done (zcode, `agent/zcode/m8-u3-errors`):**
  the D3 contract is mechanically enforced. Helpers in monitor.zig
  (`unknown_command`, `usage_sub`, `error_line`, `error_puts`); exec's
  three shapes (unknown verb incl. the empty verb, arity usage+hint,
  too-many error); shell.zig's line-level shapes; ~120 failure sites
  across the 40 handlers migrated (`error:`-prefixed refusals; usage
  lines gained the registry-blurb hint via `usage_sub` — 13 converted
  from the old `<cmd>: usage:` form); honest status reports deliberately
  kept unprefixed (ls/net/screen/usb device reports, handoff's verdict
  column, kill-armed). The canonical transcript regenerated with the D3
  misuse section (the U1 precedent for sanctioned transcript change).
  New deterministic fuzzes: tokenizer (512 garbage lines) and handlers
  (every command x junk argv — no panic; 16 side-effect-free commands
  shape-checked line-by-line; garbage verbs pinned to the unknown shape
  incl. case-sensitivity). The fuzz caught one real fourth shape in
  development (beans' range message). Live-gate assertions re-derived
  (lineedit re-run green; tcp refusal prefixed; others swept clean).
  Class A fully green.
