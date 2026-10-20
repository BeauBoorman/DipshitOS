#!/usr/bin/env bash
#
# build-goassist.sh -- build GOASSIST.ELF (user/go/goassist, M140b
# issue #2785) with the GOOS=virelai fork toolchain, the same way
# tools/go/build-goinfer.sh builds GOINFER.
# Output: .build/go/GOASSIST.ELF
#
# GOASSIST ships in image/apps.txt (undocked) and is the go-assist
# gate's payload, staged into the gate share by the spec's own setup
# hook. Weights are NEVER built or staged here: the app reads the
# staged VIW at /host/GOINFER/SMOLLM2.VIW (the M111c seam), and absent
# weights are a named refusal.
#
# Usage:
#   bash tools/go/build-goassist.sh            # build + stamp
#   bash tools/go/build-goassist.sh check      # refuse missing/stale
#   bash tools/go/build-goassist.sh stamp      # re-stamp a built ELF
#   bash tools/go/build-goassist.sh stage DIR  # copy ELF into a gate share
#
# Freshness follows the ensure-guest-elf.sh convention (issue #1503): a
# .stamp sibling of the ELF records v1 + the source hash (all of user/go/**
# plus this script and the toolchain id) + the ELF sha256. `check` fails
# closed with a named error when the stamp does not match — a stale binary
# left over from another branch can never satisfy a gate.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="goassist"
NAME="GOASSIST"
MAX_BYTES=2097152 # kernel/src/exec.zig exec_program_max

log() { printf 'build-goassist: %s\n' "$*"; }

OUT_DIR="$REPO/.build/go"
OUT="$OUT_DIR/$NAME.ELF"

# stamp_check/stamp_write mirror ensure-guest-elf.sh's v1 recipe for the
# single app GOASSIST (that helper's app table is d2-adjacent, not ours).
py_stamp() {
    python3 - "$REPO" "$OUT_DIR" "$NAME" "$1" <<'PY'
import hashlib, os, sys

ROOT, OUTDIR, NAME, cmd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
APP_BUILDER = "tools/go/build-goassist.sh"

def die(msg, rc=1):
    sys.stderr.write(msg + "\n")
    sys.exit(rc)

def elf_path():
    return os.path.join(OUTDIR, NAME + ".ELF")

def stamp_path():
    return elf_path() + ".stamp"

def toolchain_id():
    env = os.environ.get("ENSURE_GUEST_ELF_TOOLCHAIN")
    if env is not None:
        return env
    fork = os.environ.get("GO_FORK_DIR") or os.path.join(os.path.dirname(ROOT), "go-virelai")
    go = os.path.join(fork, "bin", "go")
    if os.path.isfile(go) and os.access(go, os.X_OK):
        import subprocess
        try:
            out = subprocess.check_output([go, "version"], stderr=subprocess.DEVNULL, timeout=8)
            return out.decode("utf-8", "replace").strip()
        except (subprocess.SubprocessError, OSError):
            return ""
    return ""

def file_digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def source_hash():
    h = hashlib.sha256()
    h.update(b"ensure-guest-elf-v1\n")
    h.update(("app=" + NAME + "\n").encode("utf-8"))
    h.update(("toolchain=" + toolchain_id() + "\n").encode("utf-8"))
    rels = []
    base = os.path.join(ROOT, "user", "go")
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d not in (".git", "__pycache__"))
        for name in sorted(filenames):
            if name == ".DS_Store":
                continue
            rels.append(os.path.relpath(os.path.join(dirpath, name), ROOT).replace(os.sep, "/"))
    rels.append(APP_BUILDER)
    for rel in sorted(set(rels)):
        path = os.path.join(ROOT, rel.replace("/", os.sep))
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        h.update(file_digest(path).encode("ascii") if os.path.isfile(path) else b"missing")
        h.update(b"\n")
    return h.hexdigest()

def read_stamp():
    path = stamp_path()
    if not os.path.isfile(path):
        return None
    data = open(path, encoding="utf-8", errors="replace").read().splitlines()
    if not data or data[0].strip() != "v1":
        return {"source": "", "elf": ""}
    out = {"source": "", "elf": ""}
    for line in data[1:]:
        k, _, v = line.partition("=")
        if k in out:
            out[k] = v.strip()
    return out

if cmd == "stamp":
    if not os.path.isfile(elf_path()):
        die("build-goassist: cannot stamp %s: missing" % elf_path())
    os.makedirs(OUTDIR, exist_ok=True)
    with open(stamp_path(), "w", encoding="utf-8") as f:
        f.write("v1\nsource=%s\nelf=%s\n" % (source_hash(), file_digest(elf_path())))
    sys.exit(0)

# check
elf = elf_path()
want_src = source_hash()
stamp = read_stamp()
have_src = stamp["source"] if stamp else "(none)"
have_elf = stamp["elf"] if stamp else "(none)"
want_elf = file_digest(elf) if os.path.isfile(elf) else "(none)"
if os.path.isfile(elf) and stamp is not None and have_src == want_src and have_elf == want_elf:
    sys.stdout.write("build-goassist: %s.ELF fresh (source-hash %s)\n" % (NAME, want_src))
    sys.exit(0)
status = "missing" if not os.path.isfile(elf) else "stale"
die("build-goassist: %s.ELF %s\n"
    "  path: %s\n"
    "  want source-hash: %s\n"
    "  have source-hash: %s\n"
    "  want elf-sha256:  %s\n"
    "  have elf-sha256:  %s\n"
    "  this gate refuses to boot a binary the current tree did not produce\n"
    "  rebuild: bash %s"
    % (NAME, status, elf, want_src, have_src, want_elf, have_elf, APP_BUILDER))
PY
}

build() {
    if [ ! -x "$FORK_DIR/bin/go" ]; then
        log "missing fork toolchain at $FORK_DIR/bin/go"
        log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
        exit 1
    fi
    GOPATH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-gopath.XXXXXX")"
    trap 'rm -rf "$GOPATH_DIR"' EXIT
    mkdir -p "$GOPATH_DIR/src" "$OUT_DIR"
    ln -sfn "$REPO/user/go" "$GOPATH_DIR/src/virelai"
    export GOROOT="$FORK_DIR"
    export PATH="$FORK_DIR/bin:$PATH"
    export GOTOOLCHAIN=local GO111MODULE=off GOFLAGS= GOPATH="$GOPATH_DIR" CGO_ENABLED=0
    log "building virelai/$DIR -> $OUT"
    ( cd "$REPO" && GOOS=virelai GOARCH=arm64 go build -o "$OUT" -ldflags "-s -w" "virelai/$DIR" )
    SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
    log "wrote $OUT ($SIZE bytes)"
    if [ "$SIZE" -gt "$MAX_BYTES" ]; then
        log "FAIL: $SIZE bytes exceeds exec_program_max ($MAX_BYTES); the kernel loader will refuse it"
        exit 1
    fi
    log "size ok (< $MAX_BYTES bytes)"
    py_stamp stamp
    py_stamp check
}

case "${1:-build}" in
    build)
        build
        ;;
    check)
        py_stamp check
        ;;
    stamp)
        py_stamp stamp
        ;;
    stage)
        SHARE="${2:-}"
        [ -n "$SHARE" ] || { log "usage: $0 stage <share-dir>"; exit 2; }
        py_stamp check
        mkdir -p "$SHARE"
        cp "$OUT" "$SHARE/$NAME.ELF"
        log "staged $SHARE/$NAME.ELF ($(stat -f%z "$SHARE/$NAME.ELF" 2>/dev/null || stat -c%s "$SHARE/$NAME.ELF") bytes)"
        ;;
    *)
        log "usage: $0 [build|check|stamp|stage DIR]"
        exit 2
        ;;
esac
