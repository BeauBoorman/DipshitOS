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
  `tools/gate/fixtures/bench/{pass,fail}/`.
- M119b consumes this format: `live-bench` is a normal spec in the
  discovered fleet that runs each corpus shape on VZ and fails on breach.

Do NOT tune a budget to silence a breach: a breach is the bench doing its
job — re-measure, name the new margin, and record the new baseline on the
issue.
