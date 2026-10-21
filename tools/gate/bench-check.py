#!/usr/bin/env python3
"""bench-check.py -- class-A parser + sanity check for the M119a benchmark
corpus (tools/gate/bench/corpus.tsv) and budget table
(tools/gate/bench/budgets.tsv), card #2485.

The contract this enforces:

  * both tables parse (tab-separated, '#' comments, named header row);
  * every corpus row has a non-empty op/shape/metric/unit/instrument and a
    unique `id`;
  * every budget row joins to a corpus `id` (an orphan budget fails), and
    every corpus row has at least one budget row (an unbudgeted leg is a
    measurement nothing enforces -- it does not ship);
  * cmp is `<=` or `>=`; budget and baseline are positive numbers;
  * EVERY budget cites a measured baseline and a named margin, and the
    margin is honest: for `<=` the budget must equal the baseline grown by
    the named margin (and be strictly above the baseline); for `>=` the
    budget must equal the baseline shrunk by the margin (strictly below).
    Margin grammar: `x<F>` (multiplier), `+|-<P>%` (percent), `+|-<N>`
    (additive in the row's unit). The budget may sit at the nearest
    integer to the computed bound (0.5 absolute tolerance);
  * `ref` cites where the baseline run is recorded: `#<issue>`,
    `issue:<n>`, or `gate:<id>`, optionally followed by `; <note>`.

Trend history (#2936): live-bench appends one row per verdict-bearing
measurement to artifacts/bench/history.tsv (gitignored, never committed —
the contract lives in budgets.tsv; the history is per-host evidence).
`--trend` prints the regression table over it: per corpus id, the last N
values with their delta from baseline and the recorded over-budget
verdict, plus a DRIFTING flag when the last three values all sit more
than half the named margin toward the budget — the creep warning that
fires before the budget does.

Usage:
  python3 tools/gate/bench-check.py            # real tables + fixture self-test
  python3 tools/gate/bench-check.py --check-only   # real tables only
  python3 tools/gate/bench-check.py --selftest-only # fixtures only
  python3 tools/gate/bench-check.py --corpus F --budgets F   # one pair
  python3 tools/gate/bench-check.py --trend F [--last N] [--corpus F --budgets F]

The self-test is the same reasoning as tools/gate/test-gate-run.sh: a
checker whose negative path is never exercised can be wired backwards and
still report green, so tools/gate/fixtures/bench/{pass,fail}/ prove both
directions on a CI runner with no VM anywhere. Class A: deterministic,
portable, no Apple silicon.
"""

import datetime
import math
import os
import platform
import re
import socket
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_CORPUS = os.path.join(ROOT, "tools", "gate", "bench", "corpus.tsv")
DEFAULT_BUDGETS = os.path.join(ROOT, "tools", "gate", "bench", "budgets.tsv")
DEFAULT_HISTORY = os.path.join(ROOT, "artifacts", "bench", "history.tsv")
FIXTURES = os.path.join(ROOT, "tools", "gate", "fixtures", "bench")

CORPUS_COLS = ["id", "leg", "op", "shape", "metric", "unit", "instrument"]
BUDGET_COLS = ["id", "cmp", "budget", "baseline", "margin", "ref"]
HISTORY_COLS = ["date", "rev", "host", "id", "value", "budget", "verdict"]

REF_RE = re.compile(r"^(#\d+|issue:\d+|gate:[A-Za-z0-9._-]+)(;.*)?$")
MARGIN_RE = re.compile(r"^(x(\d+(?:\.\d+)?)|([+-])(\d+(?:\.\d+)?)(%?))$")


def parse_table(path, want_cols, errors):
    """Parse one TSV table; return (header, rows) or ([], []) on failure.

    rows: list of (lineno, {col: value}) tuples for data lines.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read().splitlines()
    except OSError as e:
        errors.append("%s: cannot read table: %s" % (path, e))
        return [], []

    header = None
    rows = []
    for lineno, line in enumerate(raw, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if header is None:
            header = fields
            missing = [c for c in want_cols if c not in header]
            if missing:
                errors.append("%s:%d: header missing columns: %s"
                              % (path, lineno, ", ".join(missing)))
                return header, []
            continue
        if len(fields) > len(header):
            errors.append("%s:%d: %d fields but the header has %d "
                          "(a stray tab in a text column?)"
                          % (path, lineno, len(fields), len(header)))
            continue
        row = {}
        for i, col in enumerate(header):
            row[col] = fields[i].strip() if i < len(fields) else ""
        rows.append((lineno, row))
    if header is None:
        errors.append("%s: no header row" % path)
        return [], []
    return header, rows


def parse_number(text):
    """Parse a positive number, or None."""
    try:
        v = float(text)
    except (TypeError, ValueError):
        return None
    if math.isnan(v) or math.isinf(v) or v <= 0:
        return None
    return v


def margin_factor(margin):
    """Return (mult, add) for a named margin, or None if unparseable.

    x<F>   -> (F, 0)
    +<P>%  -> (1 + P/100, 0)
    -<P>%  -> (1 - P/100, 0)
    +<N>   -> (1, N)
    -<N>   -> (1, -N)
    """
    m = MARGIN_RE.match(margin or "")
    if not m:
        return None
    if m.group(2) is not None:
        mult = float(m.group(2))
        if mult <= 0:
            return None
        return (mult, 0.0)
    sign = 1.0 if m.group(3) == "+" else -1.0
    n = float(m.group(4))
    if n <= 0:
        return None
    if m.group(5) == "%":
        return (1.0 + sign * n / 100.0, 0.0)
    return (1.0, sign * n)


def check_pair(corpus_path, budgets_path, label):
    """Validate one (corpus, budgets) pair. Returns the error list."""
    errors = []
    _, corpus_rows = parse_table(corpus_path, CORPUS_COLS, errors)
    _, budget_rows = parse_table(budgets_path, BUDGET_COLS, errors)

    corpus_ids = {}
    for lineno, row in corpus_rows:
        rid = row.get("id", "")
        loc = "%s:%d" % (corpus_path, lineno)
        if not rid:
            errors.append("%s: empty id" % loc)
            continue
        if rid in corpus_ids:
            errors.append("%s: duplicate id %r (first at line %d)"
                          % (loc, rid, corpus_ids[rid]))
            continue
        corpus_ids[rid] = lineno
        for col in ("leg", "op", "shape", "metric", "unit", "instrument"):
            if not row.get(col, ""):
                errors.append("%s: id %s has an empty %s column" % (loc, rid, col))

    budgeted = set()
    for lineno, row in budget_rows:
        loc = "%s:%d" % (budgets_path, lineno)
        rid = row.get("id", "")
        if not rid:
            errors.append("%s: empty id" % loc)
            continue
        if rid not in corpus_ids:
            errors.append("%s: budget for %r joins to no corpus row "
                          "(an orphan budget does not ship)" % (loc, rid))
            continue
        budgeted.add(rid)

        cmp_ = row.get("cmp", "")
        if cmp_ not in ("<=", ">="):
            errors.append("%s: id %s cmp %r is not <= or >=" % (loc, rid, cmp_))

        budget = parse_number(row.get("budget", ""))
        if budget is None:
            errors.append("%s: id %s has no positive numeric budget "
                          "(a budget with no number does not ship)"
                          % (loc, rid))
        baseline = parse_number(row.get("baseline", ""))
        if baseline is None:
            errors.append("%s: id %s cites no measured baseline "
                          "(a budget with no baseline does not ship)"
                          % (loc, rid))

        ref = row.get("ref", "")
        if not ref:
            errors.append("%s: id %s cites no baseline run "
                          "(a budget with no citation does not ship)"
                          % (loc, rid))
        elif not REF_RE.match(ref):
            errors.append("%s: id %s ref %r names no recorded run "
                          "(want #<issue>, issue:<n>, or gate:<id>)"
                          % (loc, rid, ref))

        margin = row.get("margin", "")
        mf = margin_factor(margin)
        if not margin:
            errors.append("%s: id %s names no margin "
                          "(a budget must name its headroom)" % (loc, rid))
        elif mf is None:
            errors.append("%s: id %s margin %r is not x<F>, +|-<P>%%, "
                          "or +|-<N>" % (loc, rid, margin))

        # The margin is honest only when the budget IS baseline+margin.
        if (budget is not None and baseline is not None and mf is not None
                and cmp_ in ("<=", ">=")):
            mult, add = mf
            expected = baseline * mult + add
            if abs(budget - expected) > 0.5:
                errors.append("%s: id %s budget %g does not equal baseline "
                              "%g with margin %s (computed %g)"
                              % (loc, rid, budget, baseline, margin, expected))
            elif cmp_ == "<=" and not budget > baseline:
                errors.append("%s: id %s <= budget %g carries no headroom "
                              "over baseline %g" % (loc, rid, budget, baseline))
            elif cmp_ == ">=" and not budget < baseline:
                errors.append("%s: id %s >= budget %g carries no headroom "
                              "under baseline %g" % (loc, rid, budget, baseline))

    for rid in sorted(corpus_ids):
        if rid not in budgeted:
            errors.append("%s:%d: corpus row %r has no budget row "
                          "(an unbudgeted leg is a measurement nothing "
                          "enforces)" % (corpus_path, corpus_ids[rid], rid))

    return errors


# --- trend history (#2936) ---------------------------------------------------
# live-bench's benchlib.check() is the single verdict choke point — every
# leg lands exactly one verdict-bearing measurement per run there (the
# K-attempt legs check the direction-aware best of their samples; sample
# and starved receipts are attempts, not measurements). Appending here is
# what makes "one row per measurement per run" true by construction.

def _field(text):
    """One history field: a TSV cell, so no tabs/newlines ever."""
    return re.sub(r"\s+", "_", str(text)) or "?"


def host_id():
    """The host column — a stable per-machine name so a trend read still
    says WHERE each value was measured."""
    for cand in (socket.gethostname(), platform.node(),
                 os.environ.get("HOSTNAME", "")):
        if cand:
            return _field(cand)
    return "unknown"


def git_rev():
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=ROOT, stderr=subprocess.DEVNULL)
        return _field(out.decode("utf-8", "replace").strip())
    except Exception:
        return "unknown"


def append_history(row_id, value, budget, verdict, path=None):
    """Append one measurement row to the trend history (date, rev, host,
    id, value, budget, verdict). The file is gitignored local evidence —
    it is created on first write, never committed, and a missing or
    unwritable directory is a real failure (the caller's run should see
    it), so this does not swallow OSError. `path` defaults to
    DEFAULT_HISTORY resolved at call time (the spec may redirect it)."""
    if path is None:
        path = DEFAULT_HISTORY
    os.makedirs(os.path.dirname(path), exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")
    row = [stamp, git_rev(), host_id(), _field(row_id),
           "%g" % value, _field(budget), _field(verdict)]
    need_header = not os.path.exists(path) or os.path.getsize(path) == 0
    with open(path, "a", encoding="utf-8") as f:
        if need_header:
            f.write("\t".join(HISTORY_COLS) + "\n")
        f.write("\t".join(row) + "\n")


def _parse_value(text):
    """A recorded measurement: any finite float. Unlike parse_number this
    accepts 0 — the boot-shell floor legitimately observes ticks=0 — and
    negative values (history displays whatever was recorded)."""
    try:
        v = float(text)
    except (TypeError, ValueError):
        return None
    if math.isnan(v) or math.isinf(v):
        return None
    return v


def _margin_headroom(baseline, budget_text, margin):
    """The named margin as a distance from baseline. margin_factor is the
    contract-checked source; a missing/unparseable margin falls back to
    |budget - baseline| so the table still says something."""
    mf = margin_factor(margin)
    if mf is not None:
        return abs(baseline * mf[0] + mf[1] - baseline)
    budget = _parse_value(budget_text)
    if budget is not None:
        return abs(budget - baseline)
    return None


def analyze_trend(history_path, budgets_path, corpus_path=None, last=10):
    """Join the history to the budget table. Returns (errors, entries) —
    entries in first-seen history order, each:
      {id, unit, cmp, baseline, budget, margin, rows, n_total,
       drifting, over}
    rows carries the last `last` measurements (None/`last`<=0 = all) with
    delta (value - baseline) and frac (the direction-aware share of the
    named margin consumed TOWARD the budget: >0 worse than baseline, >0.5
    past half the margin). drifting fires when the last three values all
    have frac > 0.5; over when the latest recorded verdict is breach."""
    errors = []
    _, hrows = parse_table(history_path, HISTORY_COLS, errors)
    _, brows = parse_table(budgets_path, BUDGET_COLS, errors)
    umap = {}
    if corpus_path:
        _, crows = parse_table(corpus_path, CORPUS_COLS, errors)
        for _, r in crows:
            umap.setdefault(r.get("id", ""), r.get("unit", "?"))
    bmap = {}
    for _, r in brows:
        bmap.setdefault(r.get("id", ""), r)

    by_id, order = {}, []
    for lineno, row in hrows:
        rid = row.get("id", "")
        v = _parse_value(row.get("value", ""))
        if not rid:
            errors.append("%s:%d: history row with an empty id"
                          % (history_path, lineno))
            continue
        if v is None:
            errors.append("%s:%d: history row for %r has no numeric "
                          "value" % (history_path, lineno, rid))
            continue
        if rid not in by_id:
            by_id[rid] = []
            order.append(rid)
        by_id[rid].append({
            "date": row.get("date", "?"), "rev": row.get("rev", "?"),
            "host": row.get("host", "?"), "value": v,
            "budget": row.get("budget", "?"),
            "verdict": row.get("verdict", "?"),
        })

    entries = []
    for rid in order:
        b = bmap.get(rid, {})
        cmp_ = b.get("cmp", "")
        baseline = _parse_value(b.get("baseline", ""))
        headroom = None
        if baseline is not None:
            headroom = _margin_headroom(baseline, b.get("budget", ""),
                                      b.get("margin", ""))
        rows = []
        for h in by_id[rid]:
            delta = frac = None
            if baseline is not None:
                delta = h["value"] - baseline
                moved = delta if cmp_ != ">=" else -delta
                if headroom:
                    frac = moved / headroom
            rows.append(dict(h, delta=delta, frac=frac))
        last3 = rows[-3:]
        drifting = (len(last3) == 3 and bool(headroom)
                    and all(r["frac"] is not None and r["frac"] > 0.5
                            for r in last3))
        entries.append({
            "id": rid, "unit": umap.get(rid, "?"), "cmp": cmp_ or "?",
            "baseline": baseline, "budget": b.get("budget", "?"),
            "margin": b.get("margin", "?"),
            "rows": rows[-last:] if last and last > 0 else rows,
            "n_total": len(rows),
            "drifting": drifting,
            "over": bool(rows) and rows[-1]["verdict"] == "breach",
        })
    return errors, entries


def print_trend(history_path, budgets_path, corpus_path=None, last=10):
    """Print the --trend regression table; rc 1 when the history itself
    cannot be read (a trend report over nothing is no report)."""
    if not os.path.exists(history_path):
        print("bench-check trend: no history at %s — run live-bench first "
              "(or pass --trend <path>)" % history_path)
        return 1
    errors, entries = analyze_trend(history_path, budgets_path,
                                    corpus_path, last)
    for e in errors:
        print("trend: WARN %s" % e)
    if not entries:
        print("bench-check trend: %s holds no usable rows" % history_path)
        return 1
    print("bench trend: %s — %d id(s), last %d value(s) each"
          % (history_path, len(entries), last))
    print("(d-base: value - baseline; marg%: share of the named margin "
          "consumed TOWARD the budget; verdict: the over-budget flag the "
          "run recorded)")
    for e in entries:
        print()
        print("== %s ==  cmp=%s budget=%s baseline=%s margin=%s unit=%s"
              % (e["id"], e["cmp"], e["budget"],
                 "%g" % e["baseline"] if e["baseline"] is not None else "?",
                 e["margin"], e["unit"]))
        print("    %-20s  %-9s  %-14s  %10s  %9s  %6s  %s"
              % ("date", "rev", "host", "value", "d-base", "marg%", "verdict"))
        for r in e["rows"]:
            print("    %-20s  %-9s  %-14s  %10s  %9s  %6s  %s"
                  % (r["date"], r["rev"], r["host"], "%g" % r["value"],
                     "%+g" % r["delta"] if r["delta"] is not None else "?",
                     "%+.0f%%" % (100 * r["frac"])
                     if r["frac"] is not None else "?",
                     r["verdict"]))
        if e["n_total"] > len(e["rows"]):
            print("    (+%d earlier row(s) not shown)"
                  % (e["n_total"] - len(e["rows"])))
        flags = []
        if e["over"]:
            flags.append("OVER-BUDGET")
        if e["drifting"]:
            flags.append("DRIFTING (last 3 all past half the named margin)")
        print("    flags: %s" % (" ".join(flags) if flags else "clean"))
    return 0


def selftest(errors_out):
    """Run the fixture tables. Returns (pass_count, fail_count)."""
    ok, bad = 0, 0
    pass_dir = os.path.join(FIXTURES, "pass")
    fail_dir = os.path.join(FIXTURES, "fail")

    for case_dir, expect_fail in ((pass_dir, False), (fail_dir, True)):
        if not os.path.isdir(case_dir):
            errors_out.append("bench-check selftest: fixture dir missing: %s" % case_dir)
            bad += 1
            continue
        names = sorted(n[:-len(".corpus.tsv")] for n in os.listdir(case_dir)
                       if n.endswith(".corpus.tsv"))
        for name in names:
            corpus = os.path.join(case_dir, name + ".corpus.tsv")
            budgets = os.path.join(case_dir, name + ".budgets.tsv")
            label = "%s/%s" % (os.path.basename(case_dir), name)
            if not os.path.exists(budgets):
                errors_out.append("selftest %s: %s has no budgets.tsv pair" % (label, corpus))
                bad += 1
                continue
            errs = check_pair(corpus, budgets, label)
            if expect_fail and not errs:
                errors_out.append("selftest %s: expected FAIL but the pair "
                                  "validated clean -- a negative path is "
                                  "not wired" % label)
                bad += 1
            elif not expect_fail and errs:
                for e in errs:
                    errors_out.append("selftest %s: %s" % (label, e))
                bad += 1
            else:
                ok += 1

    # Trend fixtures (tools/gate/fixtures/bench/trend/{pass,fail}/): each
    # case is a corpus/budgets pair plus a *.history.tsv. The pair must
    # itself be a VALID table (check_pair runs on it — the fail lives in
    # the history, never in the fixture's own contract); a pass history
    # raises no flag, a fail history must flag at least one id.
    for case_dir, expect_fail in ((os.path.join(FIXTURES, "trend", "pass"), False),
                                  (os.path.join(FIXTURES, "trend", "fail"), True)):
        if not os.path.isdir(case_dir):
            errors_out.append("bench-check selftest: fixture dir missing: %s" % case_dir)
            bad += 1
            continue
        names = sorted(n[:-len(".history.tsv")] for n in os.listdir(case_dir)
                       if n.endswith(".history.tsv"))
        for name in names:
            corpus = os.path.join(case_dir, name + ".corpus.tsv")
            budgets = os.path.join(case_dir, name + ".budgets.tsv")
            history = os.path.join(case_dir, name + ".history.tsv")
            label = "trend/%s/%s" % (os.path.basename(case_dir), name)
            missing = [p for p in (corpus, budgets)
                       if not os.path.exists(p)]
            if missing:
                errors_out.append("selftest %s: %s has no %s pair"
                                  % (label, history,
                                     os.path.basename(missing[0])))
                bad += 1
                continue
            perrs = check_pair(corpus, budgets, label)
            if perrs:
                for e in perrs:
                    errors_out.append("selftest %s: fixture tables must "
                                      "validate clean: %s" % (label, e))
                bad += 1
                continue
            terrs, entries = analyze_trend(history, budgets, corpus,
                                           last=None)
            if terrs:
                for e in terrs:
                    errors_out.append("selftest %s: %s" % (label, e))
                bad += 1
                continue
            flagged = [e["id"] for e in entries
                       if e["drifting"] or e["over"]]
            if expect_fail and not flagged:
                errors_out.append("selftest %s: expected a DRIFTING/over "
                                  "flag but the history analyzed clean -- "
                                  "a negative path is not wired" % label)
                bad += 1
            elif not expect_fail and flagged:
                errors_out.append("selftest %s: expected clean but %s "
                                  "flagged" % (label, ", ".join(flagged)))
                bad += 1
            else:
                ok += 1
    return ok, bad


def main(argv):
    corpus, budgets = DEFAULT_CORPUS, DEFAULT_BUDGETS
    check_only = selftest_only = False
    trend_path, last = None, 10
    while argv:
        a = argv[0]
        if a == "--check-only":
            check_only = True
            argv = argv[1:]
        elif a == "--selftest-only":
            selftest_only = True
            argv = argv[1:]
        elif a == "--corpus" and len(argv) >= 2:
            corpus = os.path.abspath(argv[1])
            argv = argv[2:]
        elif a == "--budgets" and len(argv) >= 2:
            budgets = os.path.abspath(argv[1])
            argv = argv[2:]
        elif a == "--trend" and len(argv) >= 2:
            trend_path = os.path.abspath(argv[1])
            argv = argv[2:]
        elif a == "--last" and len(argv) >= 2:
            try:
                last = int(argv[1])
            except ValueError:
                print("bench-check: --last wants an integer, got %r"
                      % argv[1], file=sys.stderr)
                return 2
            argv = argv[2:]
        else:
            print("bench-check: unexpected arg: %s" % a, file=sys.stderr)
            return 2

    if trend_path is not None:
        if check_only or selftest_only:
            print("bench-check: --trend combines with --corpus/--budgets/"
                  "--last only", file=sys.stderr)
            return 2
        return print_trend(trend_path, budgets, corpus, last)

    errors = []
    if not selftest_only:
        errors.extend(check_pair(corpus, budgets, "bench"))
        if errors:
            for e in errors:
                print("FAIL  %s" % e)
            print("bench-check: %d error(s) in %s + %s"
                  % (len(errors), corpus, budgets))
            return 1
        print("bench-check: corpus + budgets validate "
              "(%s, %s)" % (os.path.relpath(corpus, ROOT),
                            os.path.relpath(budgets, ROOT)))

    if not check_only:
        st_errors = []
        ok, bad = selftest(st_errors)
        for e in st_errors:
            print("FAIL  %s" % e)
        if bad:
            print("bench-check: fixture self-test: %d pass / %d FAIL" % (ok, bad))
            return 1
        print("bench-check: fixture self-test: %d/%d pass" % (ok, ok))

    print("bench-check: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
