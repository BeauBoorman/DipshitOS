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

Usage:
  python3 tools/gate/bench-check.py            # real tables + fixture self-test
  python3 tools/gate/bench-check.py --check-only   # real tables only
  python3 tools/gate/bench-check.py --selftest-only # fixtures only
  python3 tools/gate/bench-check.py --corpus F --budgets F   # one pair

The self-test is the same reasoning as tools/gate/test-gate-run.sh: a
checker whose negative path is never exercised can be wired backwards and
still report green, so tools/gate/fixtures/bench/{pass,fail}/ prove both
directions on a CI runner with no VM anywhere. Class A: deterministic,
portable, no Apple silicon.
"""

import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_CORPUS = os.path.join(ROOT, "tools", "gate", "bench", "corpus.tsv")
DEFAULT_BUDGETS = os.path.join(ROOT, "tools", "gate", "bench", "budgets.tsv")
FIXTURES = os.path.join(ROOT, "tools", "gate", "fixtures", "bench")

CORPUS_COLS = ["id", "leg", "op", "shape", "metric", "unit", "instrument"]
BUDGET_COLS = ["id", "cmp", "budget", "baseline", "margin", "ref"]

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
    return ok, bad


def main(argv):
    corpus, budgets = DEFAULT_CORPUS, DEFAULT_BUDGETS
    check_only = "--check-only" in argv
    selftest_only = "--selftest-only" in argv
    argv = [a for a in argv if a not in ("--check-only", "--selftest-only")]
    while len(argv) >= 2 and argv[0] in ("--corpus", "--budgets"):
        if argv[0] == "--corpus":
            corpus = os.path.abspath(argv[1])
        else:
            budgets = os.path.abspath(argv[1])
        argv = argv[2:]
    if argv:
        print("bench-check: unexpected args: %s" % " ".join(argv), file=sys.stderr)
        return 2

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
