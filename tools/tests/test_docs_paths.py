"""Every backticked repo path in the docs below must exist (M139d, #2782;
M157d #2937 added docs/app-authoring.md and the gate-spec check).

TEAMS.md is the ownership map agents use to stay out of each other's way —
a row naming a deleted file silently routes claims at ghosts — and the
authoring guide's adopter links rot the same way, so both docs are held to
the same rule. This test extracts backticked tokens that look like repo
paths and asserts each one resolves — directories, files, and glob
patterns alike — and separately resolves every cited
tools/gate/specs/*.spec, whether the spec path rode a backtick or only a
markdown link target.
"""
import re
import unittest
from glob import glob
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DOCS = ["docs/TEAMS.md", "docs/app-authoring.md", "docs/app-refresh.md",
        "docs/component-registry.md"]

BACKTICK = re.compile(r"`([^`\n]+)`")
# A token is a repo-path candidate when it contains a '/', a glob '*',
# or ends in a lowercase file extension (bare `build.zig`, `AGENTS.md`).
# A leading '/' names a guest-absolute path (/host/..., /dev/tty), never
# a repo-relative one, and a bare name's extension is lowercase only:
# uppercase tails are guest artifacts (.ELF binaries, APPS.TXT, REMOTE
# JSON), not repo files. Prose identifiers (`claim`, `implemented_count`,
# `.usb`) and placeholders (`<purpose>`) are not candidates either.
EXT = re.compile(r"^[^/]+\.[a-z0-9]{1,8}$")
EXTENSIONLESS = {"justfile", "Justfile", "Makefile", "Dockerfile",
                 "LICENSE", "NOTICE", "AGENTS"}
NOT_PATH_CHARS = set("<>()\"'=$:;[]{}|&")
# A cited gate spec is a tools/gate/specs/*.spec mention anywhere on the
# line — backticked prose or a markdown link target alike.
SPEC_REF = re.compile(r"tools/gate/specs/[A-Za-z0-9._-]+\.spec")


def is_path_candidate(word):
    if not word or word.startswith("/"):
        return False
    if any(c in word for c in NOT_PATH_CHARS):
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

    def test_cited_gate_specs_exist(self):
        failures = []
        for doc in DOCS:
            lines = (ROOT / doc).read_text().splitlines()
            for lineno, line in enumerate(lines, 1):
                for ref in SPEC_REF.findall(line):
                    if not (ROOT / ref).exists():
                        failures.append(f"{doc}:{lineno}: {ref!r} does not exist")
        self.assertEqual(
            [], failures,
            "cited gate specs that do not exist:\n  " + "\n  ".join(failures),
        )


if __name__ == "__main__":
    unittest.main()
