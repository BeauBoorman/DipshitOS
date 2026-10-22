---
title: Benchmarks
parent: evidence
status: published
tags: [evidence, benchmarks, performance]
---

# Benchmarks — performance as a contract

M119 made performance a contract rather than a vibe: a measured corpus, a
budget table, and a live gate that fails on breach. The pieces live under
`tools/gate/bench/` and the gate is an ordinary member of the
[[live-gates|class-B fleet]] — `just gate live-bench`.

## Corpus and budgets

Two TSV files carry the whole system:

- [`corpus.tsv`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/tools/gate/bench/corpus.tsv)
  defines **what** is measured. Each row pins an operation, a run shape
  (device flags + the scripted op), the exact serial marker and field that
  carries the value, the unit, and where the instrument lives. "Which
  shapes" is itself a contract: the bench measures *this* shape, not a
  neighbouring one.
- [`budgets.tsv`](https://github.com/drawmeanelephant/VirelaiOS/blob/main/tools/gate/bench/budgets.tsv)
  pins **the contract number** for each row: `budget = baseline × margin`,
  where the baseline is a *measured* value recorded on the cited issue or
  gate run and the margin is named headroom (`x4`, `+400%`, `-75%`, `-8`).
  `cmp` is `<=` for latency/wall bounds and `>=` for throughput/counts. A
  row with no baseline, no margin, or no citation does not ship.

The class-A half is `tools/gate/bench-check.py`, wired into
`just verify-portable`: it parses both tables, enforces the join both ways
(no orphan budget, no unbudgeted leg), verifies the arithmetic, and
self-tests against fixtures — so an unenforced measurement cannot reach
`main`.

## The live-bench gate

`live-bench` is a normal spec: it stages the fixture ELFs, boots each corpus
shape on VZ, and each leg emits a receipt line —
`bench: id=... observed=... verdict=ok|breach|starved|sample`. Its sampling
policy is written down, not improvised:

- **A measurement is never retried** — a measured value is a sample,
  recorded, never re-drawn for luck.
- Legs with observed instability run **K=3 attempts** and the verdict checks
  one aggregate: the *direction-aware best* sample (min for `<=`, max for
  `>=`), because each baseline was itself a best-case observation and a real
  regression moves every sample.
- Starvation tolerance is allowed only on a named signature — e.g. the
  `smp-scale` c2/c4 legs may drop an attempt on the documented
  no-preemption placement race, but all-starved is a FAIL, and a
  `hf-read` with no rate in 300 s is a hang, not a flake.

The card's second deliverable is a **forced-breach negative**: point
`LIVE_BENCH_BUDGETS` at a sabotaged table (say, an inflated `hf-read` floor)
and the run must fail with a `verdict=breach` receipt naming the row. The
gate proves it can say no.

And because the contract lives in git while evidence lives per-host,
`live-bench` appends every verdict-bearing measurement to
`artifacts/bench/history.tsv` — gitignored, append-only — and
`bench-check.py --trend` prints the drift table (`DRIFTING` when three
consecutive values sit past half the margin toward budget), so creep is
visible before it becomes a breach.

## The corpus today

| Row | What it measures | Budget |
|-----|------------------|--------|
| `boot-shell` | kernel seize → first monitor prompt (1 Hz uptime ticks) | ≤ 4 ticks |
| `gosh-cmd-ls` / `gosh-cmd-echo` | GOSH command latency via the `time` builtin | ≤ 0.05 s |
| `hf-read` | host-file-channel read throughput on a >8 MiB ELF | ≥ 20,233 KiB/s |
| `app-launch-cold` | monitor `exec` → the app's first window marker | ≤ 12 ticks |
| `go-rss` | a Go app's resident footprint (`sys_procs` v2) after idle | ≤ 11,968,520 B |
| `pcm-drain` | virtio-snd submit-to-drain buffered latency | ≤ 8,192 B |
| `wm-present-cadence` / `wm-present-latency` | WM present interval and worst input→present latency under a pointer burst | ≤ 2,554 ms / ≤ 1,404,870 µs |
| `smp-scale-c1/c2/c4` | the same accounted workload at 1/2/4 cores (CNTPCT ticks) | x4/x4/x2 over baseline |
| `seat-mbox-burst` | seat mailbox posts accepted under sustained PCM | ≥ 24 of 40 |
| `seat-key-latency` | keystroke→present under a three-Go-runtime seat | ≤ 1,999,554 µs |
| `timer-jitter` | deadline-overlay fire lateness sweep | ≤ 23,480 µs |

## The named bounds it already characterized

The bench exists to name walls, and it has already paid off several times:

- **The wav-toast mailbox starvation** — under sustained PCM, the seat's
  input/mailbox drain starved and dropped keystroke bursts (the M99 named
  finding). M119c raised the ring **8 → 32** and `seat-mbox-burst` now
  contracts ≥ 24 of 40 posts accepted.
- **The spawn bound** — characterizing the task pool showed the 16-slot
  ceiling plus a pid-0 wait fix; M129 then raised the pool to **64** and
  added the spawn-storm leg.
- **The USB-MSD → VZ restore wall** — the bounded refusal is recorded with
  both reason strings: `VZ-RESTORE: refused code=12` on saturation, with
  the VirtioFS fallback named as the supported path.
- **Keystroke latency and timer jitter** — `seat-key-latency` sits at about
  one heartbeat tick (~1.0 s) on the three-runtime seat shape, and
  `timer-jitter`'s tail (the ~1 ms IRQ-side retry deferrals under
  `sched_lock` contention) is documented and budgeted ×5, not silently
  absorbed.

## Headroom legs

Beside the bench proper, five fleet members are the headroom contract —
they all passed in the M119f acceptance run: `live-scale` and
`live-smp-scale` (process and core scaling), `live-m16-resources` (the
grown-pool budget), `live-wm-pacing` (the present-cadence instrument the
`wm-present` rows reuse), and `live-observe` (the observability overhead
bound).

<Aside kind="info">

**VERIFIED.** `live-bench` went 18/18 green at `615229ed` on the dev host
(issue #2490), including a re-pin after a correctness fix moved the
`wm-present-latency` baseline — the rule is *re-measure, name the new
margin, record the new baseline on the issue*, never tune a budget to
silence a breach.

</Aside>

<Aside kind="warning">

**LIMITATION.** Budgets are per-host measurements, not physics: baselines
were recorded on the reference host and margins exist to absorb intra-host
spread (the `hf-read` margin is `-75%` because the same shape swung ~3×
between boots). M119 is landed; the reference-host full-fleet pass and K=3
soak are an owner-run background check, and index #2452 closes on owner
sign-off.

</Aside>
