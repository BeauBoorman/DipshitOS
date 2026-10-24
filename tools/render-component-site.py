#!/usr/bin/env python3
"""site/components.md renderer — M189c, issue #3227.

Renders the canonical component registry (docs/component-registry.md)
into the public site page's generated table region. The page's front
matter and prose are authored by hand; everything between the BEGIN/END
markers is this script's output. Run with no arguments to rewrite the
committed page in place (idempotent when in sync):

    python3 tools/render-component-site.py [--check]

--check exits 1 when the committed region differs from a fresh render,
which is what the docs-gate freshness check calls.

No new toolchain: python3, same as every other gate script.
"""

import argparse
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "docs" / "component-registry.md"
SITE_PAGE = ROOT / "site" / "components.md"
BEGIN = "<!-- BEGIN generated component-registry table (docs/component-registry.md) -->"
END = "<!-- END generated component-registry table -->"


def render_region() -> str:
    """The registry's table sections, verbatim, as the page's region body."""
    lines = REGISTRY.read_text().splitlines(keepends=True)
    sections, cur = [], None
    for line in lines:
        if line.startswith("## "):
            cur = [line]
            sections.append(cur)
        elif cur is not None:
            cur.append(line)
    sections = [s for s in sections if any(l.lstrip().startswith("|") for l in s)]
    out = [BEGIN + "\n"]
    for s in sections:
        out.extend(s)
        if not out[-1].endswith("\n"):
            out[-1] += "\n"
        out.append("\n")
    out.append(END + "\n")
    return "".join(out)


def current_region() -> str:
    text = SITE_PAGE.read_text()
    start = text.index(BEGIN)
    end = text.index(END) + len(END) + 1  # + trailing newline
    return text[start:end]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit 1 when the committed region is stale")
    args = ap.parse_args()
    fresh = render_region()
    if args.check:
        try:
            committed = current_region()
        except (ValueError, OSError):
            print("components.md: generated region missing or malformed")
            return 1
        if committed != fresh:
            print("components.md: registry table region is stale — "
                  "run `python3 tools/render-component-site.py` "
                  "(M189c freshness guard)")
            return 1
        print("components.md: registry region in sync")
        return 0
    text = SITE_PAGE.read_text()
    start = text.index(BEGIN)
    end = text.index(END) + len(END) + 1
    SITE_PAGE.write_text(text[:start] + fresh + text[end:])
    print("components.md: rendered registry region from component-registry.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
