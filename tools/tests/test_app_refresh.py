"""Drift check + staleness report for docs/app-refresh.md (M192a, #3246).

The refresh ledger is the rotation index for app-refresh waves: one row
per image/apps.txt entry carrying the card that last touched the app and
the ISO-8601 date. As a unittest (it rides `just verify-portable` beside
test_component_registry.py) it fails when:

  * a row is not exactly five cells (`app | binary | last refresh | date
    | notes`);
  * an apps.txt row has no ledger row or more than one, a ledger row
    names a binary the manifest does not carry, or the ledger's row
    order drifts from manifest order (coverage, both directions);
  * an `app` cell disagrees with the manifest display name on the same
    row;
  * a `date` cell is not ISO-8601 `YYYY-MM-DD` (`—` is allowed, but only
    when `last refresh` is `—` too — an untracked row);
  * a `last refresh` cell is neither `—` nor card tokens (`MnnnX`,
    `#issue`).

As a script — `python3 tools/tests/test_app_refresh.py --stale` — it
prints the table oldest-first for wave filers (`—` dates sort oldest).
That mode is advisory only: staleness is never a gate, time is not a
build input, and --stale exits 0 regardless.
"""
import re
import sys
import unittest
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LEDGER = ROOT / "docs/app-refresh.md"
APPS_TXT = ROOT / "image/apps.txt"

REF_TOKEN_RE = re.compile(r"^(?:M[0-9A-Za-z]+|#\d+)$")
EPOCH = date.min


def ledger_rows():
    """(lineno, cells) for every `|` row in the ledger.

    Header and separator lines are excluded; a `|` line that is neither
    is yielded verbatim so the grammar test flags a malformed row rather
    than skipping it.
    """
    rows = []
    for lineno, line in enumerate(LEDGER.read_text().splitlines(), 1):
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if all(set(c) <= {"-", ":", " "} and c for c in cells):
            continue  # separator row
        if cells[0] in ("app", ""):
            continue  # header row
        rows.append((lineno, cells))
    return rows


def apps_txt_rows():
    """(binary, display name) for each image/apps.txt row, in order."""
    rows = []
    for line in APPS_TXT.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "|" not in line:
            continue
        fields = [f.strip() for f in line.split("|")]
        rows.append((fields[0], fields[1]))
    return rows


def parse_date(cell):
    """date for an ISO-8601 cell, EPOCH for `—`, else None."""
    if cell == "—":
        return EPOCH
    try:
        return date.fromisoformat(cell)
    except ValueError:
        return None


class TestAppRefresh(unittest.TestCase):
    def test_row_grammar(self):
        fails = []
        for lineno, cells in ledger_rows():
            where = f"app-refresh.md:{lineno}"
            if len(cells) != 5:
                fails.append(
                    f"{where}: row has {len(cells)} cells, expected 5 — malformed row"
                )
                continue
            app, binary, refresh, dt, notes = cells
            if not app or not binary or not notes:
                fails.append(f"{where}: app, binary and notes must be non-empty")
            if refresh != "—":
                tokens = refresh.split()
                bad = [t for t in tokens if not REF_TOKEN_RE.match(t)]
                if bad:
                    fails.append(
                        f"{where}: last-refresh token(s) {bad} not in "
                        "grammar (MnnnX or #issue)"
                    )
            d = parse_date(dt)
            if d is None:
                fails.append(f"{where}: date {dt!r} is not ISO-8601 YYYY-MM-DD")
            elif d is EPOCH and refresh != "—":
                fails.append(
                    f"{where}: date '—' but last refresh names {refresh!r}"
                )
        self.assertEqual([], fails, "ledger grammar violations:\n  " + "\n  ".join(fails))

    def test_manifest_coverage_and_order(self):
        manifest = apps_txt_rows()
        ledger = [c for _, c in ledger_rows() if len(c) == 5]
        fails = []
        seen = {}
        for lineno, cells in ledger_rows():
            if len(cells) != 5:
                continue
            if cells[1] in seen:
                fails.append(
                    f"app-refresh.md:{lineno}: duplicate ledger row for {cells[1]} "
                    f"(first at line {seen[cells[1]]})"
                )
            seen[cells[1]] = lineno
        manifest_bins = [b for b, _ in manifest]
        ledger_bins = [c[1] for c in ledger]
        for b in sorted(set(manifest_bins) - set(ledger_bins)):
            fails.append(f"apps.txt row {b} has no ledger row")
        for b in sorted(set(ledger_bins) - set(manifest_bins)):
            fails.append(f"ledger row {b} is not in apps.txt")
        if ledger_bins and manifest_bins and ledger_bins != manifest_bins:
            fails.append("ledger row order differs from apps.txt order")
        names = dict(manifest)
        for lineno, cells in ledger_rows():
            if len(cells) == 5 and cells[1] in names and cells[0] != names[cells[1]]:
                fails.append(
                    f"app-refresh.md:{lineno}: app {cells[0]!r} disagrees with "
                    f"manifest display name {names[cells[1]]!r}"
                )
        self.assertEqual([], fails, "apps.txt <-> ledger drift:\n  " + "\n  ".join(fails))


def stale_report():
    """The ledger table, oldest row first (`—` dates sort oldest)."""
    rows = []
    order = {b: i for i, (b, _) in enumerate(apps_txt_rows())}
    for lineno, cells in ledger_rows():
        if len(cells) != 5:
            continue
        app, binary, refresh, dt, notes = cells
        rows.append((parse_date(dt) or EPOCH, order.get(binary, lineno), cells))
    rows.sort(key=lambda r: (r[0], r[1]))
    table = [("APP", "BINARY", "LAST REFRESH", "DATE")] + [
        (c[0], c[1], c[2], c[3]) for _, _, c in rows
    ]
    widths = [max(len(row[i]) for row in table) for i in range(4)]
    out = []
    for i, row in enumerate(table):
        line = "  ".join(cell.ljust(widths[j]) for j, cell in enumerate(row))
        out.append(line.rstrip())
        if i == 0:
            out.append("  ".join("-" * w for w in widths))
    return "\n".join(out)


if __name__ == "__main__":
    if "--stale" in sys.argv:
        print(stale_report())
    else:
        unittest.main()
