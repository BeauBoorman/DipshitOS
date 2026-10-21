# bench/ — the M119a benchmark corpus + budget table (#2485)

"Performance is a contract" (index #2452): `corpus.tsv` defines WHAT is
measured (which ops, which shapes, which serial marker, which unit);
`budgets.tsv` pins the contract number for each row — `budget = baseline
x margin`, where the baseline is a MEASURED value recorded on the cited
issue/run and the margin is the named headroom. A row with no baseline,
no margin, or no citation does not ship.

- `corpus.tsv` — the corpus. Columns: `id leg op shape metric unit
  instrument`. `id` is unique; `leg` groups rows sharing an instrument
  (wm-present) or a shape at several sizes (smp-scale-c1/c2/c4).
- `budgets.tsv` — the budget table. Columns: `id cmp budget baseline
  margin ref`. `cmp` is `<=` (upper bound) or `>=` (lower bound);
  `margin` is `x<F>`, `+|-<P>%`, or `+|-<N>` in the row's unit; `ref` is
  `#<issue>`, `issue:<n>`, or `gate:<id>`.
- `tools/gate/bench-check.py` — the class-A parser + sanity check
  (wired into `just verify-portable`). It parses both tables, enforces
  the join both ways (orphan budget / unbudgeted leg), verifies the
  `budget = baseline x margin` arithmetic, and self-tests against
  `tools/gate/fixtures/bench/{pass,fail}/` (tables) and
  `tools/gate/fixtures/bench/trend/{pass,fail}/` (histories, #2936).
- M119b consumes this format: `live-bench` is a normal spec in the
  discovered fleet that runs each corpus shape on VZ and fails on breach.

## Trend history (#2936)

`live-bench` appends one row per verdict-bearing measurement to
`artifacts/bench/history.tsv`: `date`, `rev`, `host`, `id`, `value`,
`budget` (the number actually enforced that run), `verdict`. The file is
**never committed** — `artifacts/` is gitignored on purpose: a history is
per-host, append-only evidence, and the contract it is evidence ABOUT is
`budgets.tsv`, which lives in git. Committing it would pin one machine's
noise as another machine's expectation.

See the creep before it becomes a breach:

    python3 tools/gate/bench-check.py --trend artifacts/bench/history.tsv [--last N]

prints, per corpus id, the last N values (default 10) with delta from
baseline and the recorded over-budget verdict, plus `DRIFTING` when the
last three values all sit more than half the named margin toward the
budget. `live-bench` prints the same table at the end of every run.

Do NOT tune a budget to silence a breach: a breach is the bench doing its
job — re-measure, name the new margin, and record the new baseline on the
issue.
