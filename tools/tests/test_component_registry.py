"""Drift check for docs/component-registry.md (M189a, #3225).

The registry is the canonical component -> version-surface map; this test
is what keeps it from silently lying. It parses the six-cell table rows
and fails when:

  * an image/apps.txt executable has no `app` row, or an `app` row names
    a binary the manifest does not carry (both directions — coverage);
  * a non-app row's binary is not produced anywhere in the build/staging
    path (build.zig, image/, tools/*.sh, tools/*.py);
  * a cited tools/gate/specs/*.spec, `ADR NNNN`, `Release*` const, or
    repo path does not resolve;
  * an `appver N` cell disagrees with the `StateVersion` the app's
    package under user/go/ registers with the tabapp harness — or with
    the version a non-tabapp app stamps on the envelope itself via a
    direct `PostStateSave` call — in either direction, so a new
    registration showing `—` is drift too;
  * a cell carries a kind/state/version token outside the grammar the
    registry documents in its "Row grammar" section.
"""
import re
import unittest
from glob import glob
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = ROOT / "docs/component-registry.md"
APPS_TXT = ROOT / "image/apps.txt"
RELEASE_GO = ROOT / "user/go/store/release.go"
OSVER = ROOT / "kernel/src/osver.zig"

KINDS = {"app", "seat", "tool", "fixture", "lib", "kernel-service", "host-tool"}
STATES = {"shipped", "staged", "fixture", "retained-fallback", "host"}

BINARY_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,24}\.(?:ELF|BIN|SO|EFI)$")
ANY_BINARY_RE = re.compile(r"\b[A-Z][A-Z0-9_]{0,24}\.(?:ELF|BIN|SO|EFI)\b")
SPEC_RE = re.compile(r"^tools/gate/specs/[A-Za-z0-9._-]+\.spec$")
ADR_RE = re.compile(r"^ADR\s+(\d{4})$")
APPVER_RE = re.compile(r"^appver\s+(\d+)$")
PIN_RE = re.compile(r"^pin\s+(\S+)$")
RELEASE_CONST_RE = re.compile(r"^Release[A-Z][A-Za-z0-9]*$")
STATEVERSION_RE = re.compile(r"StateVersion:\s*([A-Za-z_][A-Za-z0-9_]*|\d+)")
# An app outside the tabapp harness stamps the envelope itself; the
# version is PostStateSave's second argument. The trailing [,)] keeps a
# dotted receiver (t.StateVersion) from matching — that is a field read,
# not a literal the const pass can resolve.
POSTSTATESAVE_RE = re.compile(
    r"PostStateSave\([^,]+,\s*([A-Za-z_][A-Za-z0-9_]*|\d+)\s*[,)]"
)


def registry_rows():
    """(lineno, cells) for every `|` row in the file.

    Header and separator lines are excluded; a `|` line that is neither a
    header, a separator, nor a six-cell row is yielded as a one-cell row so
    the grammar test can flag it as malformed rather than skipping it.
    """
    rows = []
    for lineno, line in enumerate(REGISTRY.read_text().splitlines(), 1):
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if all(set(c) <= {"-", ":", " "} and c for c in cells):
            continue  # separator row
        if cells[0] in ("name", ""):
            continue  # header row
        rows.append((lineno, cells))
    return rows


def apps_txt_executables():
    names = set()
    for line in APPS_TXT.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "|" not in line:
            continue
        names.add(line.split("|", 1)[0].strip())
    return names


def produced_binaries():
    """Every NAME.ELF/BIN/SO/EFI the build or staging path can produce."""
    corpus = set(apps_txt_executables())
    files = [ROOT / "build.zig"]
    files += glob(str(ROOT / "image/*"))
    files += glob(str(ROOT / "tools/**/*.sh"), recursive=True)
    files += glob(str(ROOT / "tools/**/*.py"), recursive=True)
    for f in files:
        p = Path(f)
        if p.is_file():
            corpus.update(ANY_BINARY_RE.findall(p.read_text(errors="replace")))
    return corpus


def release_grammar_consts():
    """requiredConsts + optionalConsts in user/go/store/release.go."""
    text = RELEASE_GO.read_text()
    consts = set()
    for var in ("requiredConsts", "optionalConsts"):
        m = re.search(var + r"\s*=\s*\[\]string\{(.*?)\}", text, re.S)
        assert m, f"{var} not found in {RELEASE_GO}"
        consts.update(re.findall(r'"([A-Za-z]+)"', m.group(1)))
    return consts


def app_package_dir(binary):
    """GOCLOCK.ELF -> user/go/goclock; None for non-Go binaries."""
    stem = binary[:-4].lower() if binary.endswith(".ELF") else None
    if stem is None:
        return None
    candidates = [stem]
    if stem.startswith("go"):
        candidates.append(stem[2:])
    extra = {"web": "browser", "gostalgia": "gsport"}.get(stem)
    if extra:
        candidates.append(extra)
    for cand in candidates:
        if cand and (ROOT / "user/go" / cand).is_dir():
            return ROOT / "user/go" / cand
    return None


def registered_state_versions(pkg_dir):
    """The distinct integer versions a package stamps on state envelopes.

    Two surfaces feed it: `StateVersion:` field values (tabapp
    registrations) and the version argument of direct `PostStateSave`
    calls (apps that carry the envelope outside the harness, like
    browser's stateAppVer). Two passes: collect literal and const-token
    values across the package, then resolve const-valued ones against
    every non-test file (the registration and the const usually live in
    different files). A set is returned so more than one distinct value
    is visible to the caller — one registration is the contract, two is
    ambiguity the test flags.
    """
    texts = [
        go.read_text(errors="replace")
        for go in sorted(pkg_dir.glob("*.go"))
        if not go.name.endswith("_test.go")
    ]
    values = set()
    pending = []
    for text in texts:
        for pattern in (STATEVERSION_RE, POSTSTATESAVE_RE):
            for m in pattern.finditer(text):
                token = m.group(1)
                if token.isdigit():
                    values.add(int(token))
                else:
                    pending.append(token)
    for token in pending:
        pat = re.compile(
            r"(?:const\s+)?" + re.escape(token) + r"\s*(?:u?int?\d*\s*)?=\s*(\d+)\b"
        )
        for text in texts:
            cm = pat.search(text)
            if cm:
                values.add(int(cm.group(1)))
                break
    return values


class TestComponentRegistry(unittest.TestCase):
    def test_row_grammar(self):
        fails = []
        for lineno, cells in registry_rows():
            where = f"component-registry.md:{lineno}"
            if len(cells) != 6:
                fails.append(
                    f"{where}: row has {len(cells)} cells, expected 6 — malformed row"
                )
                continue
            name, kind, binary, version, owning, state = cells
            if kind not in KINDS:
                fails.append(f"{where}: kind {kind!r} not in {sorted(KINDS)}")
            if state not in STATES:
                fails.append(f"{where}: state {state!r} not in {sorted(STATES)}")
            if binary != "—":
                if kind == "host-tool":
                    if "/" not in binary:
                        fails.append(
                            f"{where}: host-tool binary {binary!r} is not a repo path"
                        )
                    elif not (ROOT / binary).exists():
                        fails.append(f"{where}: host-tool root {binary!r} missing")
                elif not BINARY_RE.match(binary):
                    fails.append(f"{where}: binary {binary!r} is not a staged name")
            if kind == "lib" and binary != "—":
                fails.append(f"{where}: lib row carries binary {binary!r}")
            for token in [t.strip() for t in version.split(",")]:
                if token == "—" or APPVER_RE.match(token) or token == "osver":
                    continue
                am = ADR_RE.match(token)
                if am:
                    if not glob(str(ROOT / "docs/decisions" / f"{am.group(1)}-*.md")):
                        fails.append(f"{where}: {token!r} has no docs/decisions file")
                    continue
                if RELEASE_CONST_RE.match(token):
                    continue
                pm = PIN_RE.match(token)
                if pm:
                    if not (ROOT / pm.group(1)).exists():
                        fails.append(f"{where}: pin file {pm.group(1)!r} missing")
                    continue
                fails.append(f"{where}: version token {token!r} not in grammar")
            for token in [t.strip() for t in owning.split(",")]:
                if token == "—":
                    continue
                if SPEC_RE.match(token):
                    if not (ROOT / token).exists():
                        fails.append(f"{where}: spec {token!r} does not exist")
                    continue
                am = ADR_RE.match(token)
                if am:
                    if not glob(str(ROOT / "docs/decisions" / f"{am.group(1)}-*.md")):
                        fails.append(f"{where}: {token!r} has no docs/decisions file")
                    continue
                if (ROOT / token).exists():
                    continue
                fails.append(f"{where}: owning ref {token!r} does not resolve")
        self.assertEqual([], fails, "registry grammar violations:\n  " + "\n  ".join(fails))

    def test_apps_txt_coverage(self):
        manifest = apps_txt_executables()
        rows = registry_rows()
        app_bins = {cells[2] for _, cells in rows if len(cells) == 6 and cells[1] == "app"}
        fails = sorted(
            [f"apps.txt row {n} has no registry app row" for n in manifest - app_bins]
            + [f"registry app row {n} is not in apps.txt" for n in app_bins - manifest]
        )
        self.assertEqual([], fails, "apps.txt <-> registry drift:\n  " + "\n  ".join(fails))

    def test_binaries_are_produced(self):
        corpus = produced_binaries()
        fails = []
        for lineno, cells in registry_rows():
            if len(cells) != 6:
                continue
            name, kind, binary = cells[0], cells[1], cells[2]
            if kind in ("app", "lib", "host-tool") or binary == "—":
                continue
            if binary not in corpus:
                fails.append(
                    f"component-registry.md:{lineno}: {binary} ({name}) is not "
                    "produced by build.zig, image/, or tools/"
                )
        self.assertEqual([], fails, "unproduced binaries:\n  " + "\n  ".join(fails))

    def test_release_consts_in_grammar(self):
        grammar = release_grammar_consts()
        fails = []
        for lineno, cells in registry_rows():
            if len(cells) != 6:
                continue
            for cell in (cells[3], cells[4]):
                for token in [t.strip() for t in cell.split(",")]:
                    if RELEASE_CONST_RE.match(token) and token not in grammar:
                        fails.append(
                            f"component-registry.md:{lineno}: {token} is not in "
                            "the release grammar (user/go/store/release.go)"
                        )
        self.assertEqual([], fails, "const drift:\n  " + "\n  ".join(fails))

    def test_appver_matches_state_version(self):
        fails = []
        for lineno, cells in registry_rows():
            if len(cells) != 6:
                continue
            name, kind, binary, version = cells[0], cells[1], cells[2], cells[3]
            declared = [int(m.group(1)) for m in
                        (APPVER_RE.match(t.strip()) for t in version.split(","))
                        if m]
            pkg = app_package_dir(binary) if binary != "—" else None
            actual = registered_state_versions(pkg) if pkg else set()
            if len(actual) > 1:
                fails.append(
                    f"component-registry.md:{lineno}: {binary} registers "
                    f"ambiguous StateVersions {sorted(actual)}"
                )
                continue
            if declared:
                if len(declared) != 1:
                    fails.append(f"component-registry.md:{lineno}: multiple appver tokens")
                    continue
                if pkg is None:
                    fails.append(
                        f"component-registry.md:{lineno}: appver on {binary} but "
                        "no user/go package resolves"
                    )
                elif not actual:
                    fails.append(
                        f"component-registry.md:{lineno}: {binary} declares "
                        f"appver {declared[0]} but {pkg.relative_to(ROOT)} "
                        "registers no StateVersion"
                    )
                elif actual != {declared[0]}:
                    fails.append(
                        f"component-registry.md:{lineno}: {binary} declares "
                        f"appver {declared[0]} but the package registers {sorted(actual)[0]}"
                    )
            elif kind == "app" and actual:
                fails.append(
                    f"component-registry.md:{lineno}: {binary} registers "
                    f"StateVersion {sorted(actual)[0]} but the registry shows '—'"
                )
        self.assertEqual([], fails, "appver drift:\n  " + "\n  ".join(fails))

    def test_osver_surface_exists(self):
        rows = [c for _, c in registry_rows() if len(c) == 6 and "osver" in c[3]]
        if rows:
            self.assertTrue(OSVER.exists(), "osver cited but kernel/src/osver.zig is gone")
            self.assertIn("pub var label", OSVER.read_text())


if __name__ == "__main__":
    unittest.main()
