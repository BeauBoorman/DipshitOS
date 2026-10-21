#!/usr/bin/env bash
#
# build-btmath.sh -- build BTMATH.ELF, the Bubble Tea math trainer
# (user/go/btmath), with the GOOS=virelai fork. Charm stays in the Go module
# cache — staged and overlaid like build-charmhello.sh/build-files.sh, never
# vendored in-tree. Unlike those apps btmath runs Bubble Tea's real Program
# loop (tea.NewProgram + Run); the overlay supplies the Virelai platform
# hooks that loop needs. Output: .build/go/BTMATH.ELF
#
# Usage: bash tools/go/build-btmath.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
NAME="${GO_BUILD_NAME:-BTMATH}"
VERSION="v2.0.9"
BUBBLES_VERSION="v2.2.1"
MAX_BYTES=$((32 * 1024 * 1024)) # M72a load_max (exec_image_max): initialized ELF bytes.

log() { printf 'build-btmath: %s\n' "$*"; }

# MIT/BSD attribution for the Charm modules linked into the ELF lives in
# user/go/btmath/THIRD-PARTY.txt (sources stay in the module cache, so the
# notice has to ship separately). A version bump without re-resolving that
# file must fail here, not silently ship stale notices.
for pin in "bubbletea/v2 ${VERSION}" "bubbles/v2 ${BUBBLES_VERSION}"; do
    if ! grep -q "$pin" "$REPO/user/go/btmath/THIRD-PARTY.txt"; then
        log "FAIL: THIRD-PARTY.txt does not pin $pin; re-resolve and update it"
        exit 1
    fi
done

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

export GOROOT="$FORK_DIR"
export PATH="$FORK_DIR/bin:$PATH"
export GOTOOLCHAIN=local
export CGO_ENABLED=0

# Charm is intentionally NOT a dependency of the SDK's user/go/go.mod:
# `user/go/ttf` guards that module against broad desktop dependencies. Start
# with a gitignored cache module, then build through a transient modfile beside
# the SDK's own go.mod (Go requires a -modfile to live in that directory).
WORK_DIR="$REPO/.build/btmath-work"
MODFILE="$WORK_DIR/go.mod"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cat >"$MODFILE" <<EOF
module btmath-build

go 1.27

require (
	charm.land/bubbletea/v2 ${VERSION}
	charm.land/bubbles/v2 ${BUBBLES_VERSION}
)
EOF

# Fetch only declared Go modules into the host module cache. The app build
# remains module-mode so Charm's transitive packages resolve there; no source
# from that cache is committed or vendored into the guest tree.
( cd "$WORK_DIR" && go mod download "charm.land/bubbletea/v2@${VERSION}" \
    "charm.land/bubbles/v2@${BUBBLES_VERSION}" )

MOD_DIR="$(go env GOMODCACHE)/charm.land/bubbletea/v2@${VERSION}"
[ -f "$MOD_DIR/termios_other.go" ] || {
    log "Bubble Tea ${VERSION} missing from module cache at $MOD_DIR"
    exit 1
}

# Go intentionally refuses overlays beneath GOMODCACHE. Stage the one module
# into the gitignored build area, then point a temporary module file at it:
# this is still a module-cache build, not an in-tree vendor copy, and makes
# the two Virelai-only files visible to the compiler without mutating Charm.
STAGE="$REPO/.build/btmath-module"
if [ -d "$STAGE" ]; then
    # Module-cache sources are intentionally read-only. `cp -a` preserves
    # that mode, so make a prior staged copy removable before refreshing it.
    chmod -R u+w "$STAGE"
    rm -rf "$STAGE"
fi
mkdir -p "$STAGE"
cp -a "$MOD_DIR/." "$STAGE/"
chmod -R u+w "$STAGE"

OVERLAY="$REPO/.build/btmath-overlay.json"
mkdir -p "$(dirname "$OVERLAY")" "$REPO/.build/go"
python3 - "$STAGE" "$REPO" "$OVERLAY" <<'PY'
import json, os, sys

module, repo, out = sys.argv[1:]
replace = {
    # These originals are selected for an unknown GOOS; the overlay changes
    # their build tags and supplies the Program platform hooks without
    # pretending Virelai has termios or POSIX signals.
    os.path.join(module, "termios_other.go"): os.path.join(repo, "tools/go/overlay/charm/termios_virelai.go"),
    os.path.join(module, "signals_unix.go"): os.path.join(repo, "tools/go/overlay/charm/signals_virelai.go"),
}
with open(out, "w") as f:
    json.dump({"Replace": replace}, f, sort_keys=True)
PY

# --- charm-mods: stage the closure's platform files --------------------
# tools/go/overlay/charm-mods/<module>@<version>/ maps onto a COPY of that
# module from the cache (see charm-mods/README.md — the gostalgia-mods
# rules): a file at an existing path replaces it and must carry a
# pinned-sha256 marker for the cache original; a new path needs
# //go:build virelai; non-.go files and README.md are never applied. Each
# staged copy is re-verified against the cache snapshot, then the
# transient modfile replaces the module with the copy — the cache itself
# is never written. #2958: atotto/clipboard@v0.1.4 is the entry BTMATH
# needs — textinput imports it, and its readAll/writeAll get a virelai
# backend on the kernel's 512-byte seat clipboard.
MODS_REPLACES="$WORK_DIR/mods-replaces.txt"
python3 - "$REPO" "$WORK_DIR" "$MODS_REPLACES" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

repo, work_dir, out_file = map(Path, sys.argv[1:4])
mods_dir = repo / "tools" / "go" / "overlay" / "charm-mods"
stage_root = repo / ".build" / "charm-mods"
pin_re = re.compile(r"pinned-sha256:\s*([0-9a-f]{64})")
replaces = []

mod_dirs = sorted(d for d in mods_dir.rglob("*") if d.is_dir() and "@" in d.name) \
    if mods_dir.is_dir() else []
for mod_dir in mod_dirs:
    rel = mod_dir.relative_to(mods_dir)
    leaf = rel.name.split("@", 1)
    mod_path = str(rel.parent / leaf[0]) if str(rel.parent) != "." else leaf[0]
    mod_key = mod_path + "@" + leaf[1]

    dl = subprocess.run(
        ["go", "mod", "download", "-json", mod_key],
        cwd=work_dir, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if dl.returncode:
        sys.exit("build-btmath: module download failed for %s:\n%s" % (mod_key, dl.stderr))
    obj = json.loads(dl.stdout)
    cache_dir = Path(obj["Dir"])

    dst_root = stage_root / rel
    if dst_root.exists():
        for p in [dst_root, *dst_root.rglob("*")]:
            try:
                p.chmod(0o755 if p.is_dir() else 0o644)
            except OSError:
                pass
        shutil.rmtree(dst_root)
    shutil.copytree(cache_dir, dst_root)
    pristine = {str(p.relative_to(dst_root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in dst_root.rglob("*") if p.is_file()}
    dst_root.chmod(0o755)
    for p in dst_root.rglob("*"):
        p.chmod(0o644 if p.is_file() else 0o755)

    named = {}
    for src in sorted(mod_dir.rglob("*")):
        if not src.is_file() or src.name == "README.md":
            continue
        srel = src.relative_to(mod_dir)
        if src.suffix != ".go" or any(p in ("..", "") or p.startswith(".")
                                      for p in srel.parts) or srel.is_absolute():
            sys.exit("build-btmath: invalid charm-mods path %s" % srel)
        dst = dst_root / srel
        head = src.read_text().splitlines()[:6]
        marker = next((m.group(1) for line in head
                       if (m := pin_re.search(line))), None)
        tagged = any(line.startswith("//go:build") and "virelai" in line
                     for line in head)
        if dst.exists():
            if not marker:
                sys.exit("build-btmath: charm-mods %s replaces %s without a "
                         "pinned-sha256 marker" % (src, srel))
            got = pristine.get(str(srel))
            if got != marker:
                sys.exit("build-btmath: charm-mods %s pins sha256 %s but the "
                         "%s file has %s — the dependency moved; re-pin the overlay"
                         % (src, marker, mod_key, got))
        elif not tagged:
            sys.exit("build-btmath: charm-mods %s adds %s without "
                     "//go:build virelai" % (src, srel))
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(src.read_bytes())
        named[str(srel)] = hashlib.sha256(src.read_bytes()).hexdigest()

    expected = dict(pristine)
    expected.update(named)
    after = {str(p.relative_to(dst_root)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in dst_root.rglob("*") if p.is_file()}
    if after != expected:
        sys.exit("build-btmath: charm-mods integrity check failed for %s "
                 "(stage differs from cache at a non-overlay path)" % mod_key)
    replaces.append((mod_path, dst_root))
    print("build-btmath: staged %s with %d overlay file(s)" % (mod_key, len(named)))

with open(out_file, "w") as f:
    for path, dst in replaces:
        f.write("replace %s => %s\n" % (path, dst))
PY

TEMP_MOD="$REPO/user/go/.btmath.mod"
TEMP_SUM="${TEMP_MOD%.mod}.sum"
cp "$REPO/user/go/go.mod" "$TEMP_MOD"
cat >>"$TEMP_MOD" <<EOF

require (
	charm.land/bubbletea/v2 ${VERSION}
	charm.land/bubbles/v2 ${BUBBLES_VERSION}
)
replace charm.land/bubbletea/v2 => $STAGE
EOF
cat "$MODS_REPLACES" >>"$TEMP_MOD"
trap 'rm -f "$TEMP_MOD" "$TEMP_SUM"' EXIT

OUT="$REPO/.build/go/$NAME.ELF"
log "building virelai/btmath with Bubble Tea ${VERSION} + Bubbles ${BUBBLES_VERSION} -> $OUT"
( cd "$REPO/user/go" &&
    GOOS=virelai GOARCH=arm64 go build -mod=mod -modfile "$TEMP_MOD" -overlay "$OVERLAY" \
        -ldflags "-s -w" -o "$OUT" ./btmath )

SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
log "wrote $OUT ($SIZE bytes)"
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    log "FAIL: $SIZE bytes exceeds M72a load_max ($MAX_BYTES)"
    exit 1
fi
log "size ok (<= M72a 32 MiB initialized-image bound; module-cache Charm, no vendor tree)"
