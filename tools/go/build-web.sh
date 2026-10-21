#!/usr/bin/env bash
#
# build-web.sh -- build an in-guest Go program (the browser) with the
# GOOS=virelai fork toolchain, the same way tools/go/build-go.sh builds the
# runtime fixtures.
#
# Usage: bash tools/go/build-web.sh [dir-under-user/go] [NAME] [--gate]
#   Default: browser -> .build/go/WEB.ELF, fetch -> .build/go/GOFETCH.ELF
#
# The default NAME is not cosmetic: an app looks itself up by its executable
# name to find the WM (vi.WmPeers), so a binary built under a name the app does
# not claim resolves no self and its WM request returns false BEFORE sending --
# a silent no-op with no log line. Both apps below pin their own name in
# source (appName in user/go/browser/main.go, user/go/fetch/main.go), so the
# default has to match it; anything else gets the uppercased directory, exactly
# as before.
#
# HTTPS consumers (fetch, browser) import virelai/tls and dial in-process.
# Do not stage FETCHS.BIN for those apps.
#
# Imports are written as `virelai/...` so the module path and the GOPATH path
# agree: the host `go test ./...` run uses user/go/go.mod, and this script
# points GOPATH at a temp dir with user/go linked as $GOPATH/src/virelai.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"

# Match the existing kernel loader, not the retired whole-file staging path.
# --check-elf is also a host-only negative-test seam; it does not build a VM.
check_elf() {
    python3 - "$1" <<'PY'
import os, struct, sys
path = sys.argv[1]
size = os.path.getsize(path)
def refuse(reason):
    sys.exit("build-web: FAIL: " + reason)
if size > 32 * 1024 * 1024:
    refuse("image_too_large (existing 32 MiB file limit)")
with open(path, "rb") as f:
    head = f.read(16384)
if len(head) < 64 or head[:7] != b"\x7fELF\x02\x01\x01":
    refuse("invalid ELF64 little-endian header")
etype, machine = struct.unpack_from("<HH", head, 16)
entry, phoff = struct.unpack_from("<QQ", head, 24)
phsize, phnum = struct.unpack_from("<HH", head, 54)
if etype != 2 or machine != 183 or phsize != 56 or phnum == 0 or phoff + phsize * phnum > len(head):
    refuse("invalid static AArch64 program-header table")
loads, staged = [], False
for i in range(phnum):
    typ, flags, off, va, _, filesz, memsz, _ = struct.unpack_from("<IIQQQQQQ", head, phoff + i * phsize)
    if typ in (2, 3):
        staged = True
    if typ != 1:
        continue
    if filesz > memsz or off + filesz > size:
        refuse("invalid/truncated load segment")
    loads.append((flags, off, va, filesz, memsz))
if not loads or len(loads) > 3:
    refuse("invalid PT_LOAD count")
if sum(s[3] for s in loads) > 32 * 1024 * 1024:
    refuse("segment_too_large (existing 32 MiB initialized limit)")
if sum(s[4] for s in loads) > 64 * 1024 * 1024:
    refuse("map_too_large (existing 64 MiB mapped limit)")
if loads[0][0] & 2 or not loads[0][2] <= entry < loads[0][2] + loads[0][3]:
    refuse("writable text or invalid entry")
gap = loads[0][2] != 0x400000
for prev, cur in zip(loads, loads[1:]):
    if cur[1] < prev[1] + prev[3] or cur[2] < prev[2] + prev[4]:
        refuse("overlapping file or virtual load ranges")
    gap |= cur[2] != prev[2] + prev[4]
if gap:
    for s in loads:
        if s[2] < 4096 or s[2] % 4096 or s[2] + s[4] > 0x10000000:
            refuse("invalid gap placement")
    if len(loads) > 1 and not loads[-1][0] & 2:
        refuse("read-only data segment")
    if any(s[0] & 2 for s in loads[1:-1]):
        refuse("writable rodata")
if (staged or not gap) and size > 2 * 1024 * 1024:
    refuse("staging_too_large (existing 2 MiB staged-shape limit)")
print("build-web: loader bounds ok: file=%d initialized=%d mapped=%d path=%s" %
      (size, sum(s[3] for s in loads), sum(s[4] for s in loads),
       "streamed" if gap and not staged else "staged"))
PY
}
if [ "${1:-}" = "--check-elf" ]; then
    [ "$#" -eq 2 ] || { echo "usage: build-web.sh --check-elf FILE" >&2; exit 2; }
    check_elf "$2"
    exit
fi
DIR="${1:-browser}"
case "$DIR" in
    browser) DEFAULT_NAME=WEB ;;
    fetch)   DEFAULT_NAME=GOFETCH ;;
    *)       DEFAULT_NAME="$(printf '%s' "$DIR" | tr '[:lower:]' '[:upper:]')" ;;
esac
NAME="${2:-$DEFAULT_NAME}"
TAG_ARGS=()
if [ "${3:-}" = "--gate" ]; then
    TAG_ARGS=(-tags virelai_gate_roots)
    NAME="${NAME}-GATE"
elif [ -n "${3:-}" ]; then
    echo "usage: build-web.sh [dir] [NAME] [--gate]" >&2
    exit 2
fi
[ "$#" -le 3 ] || { echo "build-web: too many arguments" >&2; exit 2; }

log() { printf 'build-web: %s\n' "$*"; }

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

GOPATH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-gopath.XXXXXX")"
trap 'rm -rf "$GOPATH_DIR"' EXIT
mkdir -p "$GOPATH_DIR/src"
ln -sfn "$REPO/user/go" "$GOPATH_DIR/src/virelai"

export GOROOT="$FORK_DIR"
export PATH="$FORK_DIR/bin:$PATH"
export GOTOOLCHAIN=local
export GO111MODULE=off
export GOFLAGS=
export GOPATH="$GOPATH_DIR"
export CGO_ENABLED=0

OUT_DIR="$REPO/.build/go"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$NAME.ELF"

log "building virelai/$DIR -> $OUT"
( cd "$REPO" && GOOS=virelai GOARCH=arm64 go build "${TAG_ARGS[@]}" -o "$OUT" -ldflags "-s -w" "virelai/$DIR" )

SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
log "wrote $OUT ($SIZE bytes)"
check_elf "$OUT"
