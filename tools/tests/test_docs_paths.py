"""Every backticked repo path in docs/TEAMS.md must exist (M139d, #2782).

TEAMS.md is the ownership map agents use to stay out of each other's way;
a row naming a deleted file silently routes claims at ghosts. This test
extracts backticked tokens that look like repo paths and asserts each one
resolves — directories, files, and glob patterns alike.
"""
import re
import unittest
from glob import glob
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DOCS = ["docs/TEAMS.md"]

BACKTICK = re.compile(r"`([^`\n]+)`")
# A token is a repo-path candidate when it contains a '/', a glob '*',
# or ends in a file extension (bare `build.zig`, `AGENTS.md`). Prose
# identifiers (`claim`, `implemented_count`, `.usb`) and placeholders
# (`<purpose>`) are not candidates.
EXT = re.compile(r"^[^/]+\.[A-Za-z0-9]{1,8}$")
EXTENSIONLESS = {"justfile", "Justfile", "Makefile", "Dockerfile",
                 "LICENSE", "NOTICE", "AGENTS"}
NOT_PATH_CHARS = set("<>()\"'=$:;[]{}|&")


def is_path_candidate(word):
    if not word or any(c in word for c in NOT_PATH_CHARS):
        return False
    return "/" in word or "*" in word or EXT.match(word) or word in EXTENSIONLESS


def resolve(word):
    """None if the path exists, else a failure description."""
    if "*" in word:
        if glob(str(ROOT / word)):
            return None
        return f"glob {word!r} matched nothing"
    if not (ROOT / word.rstrip("/")).exists():
        return f"{word!r} does not exist"
    return None


class TestDocsPaths(unittest.TestCase):
    def test_backticked_paths_exist(self):
        failures = []
        for doc in DOCS:
            lines = (ROOT / doc).read_text().splitlines()
            for lineno, line in enumerate(lines, 1):
                for token in BACKTICK.findall(line):
                    for word in token.split():
                        if not is_path_candidate(word):
                            continue
                        err = resolve(word)
                        if err:
                            failures.append(f"{doc}:{lineno}: {err}")
        self.assertEqual(
            [], failures,
            "backticked repo paths that do not exist:\n  " + "\n  ".join(failures),
        )


if __name__ == "__main__":
    unittest.main()
