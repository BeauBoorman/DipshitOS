#!/usr/bin/env bash
#
# build-goupd.sh -- build the M115f OS-update stager (user/go/goupd,
# issue #2465) with the GOOS=virelai fork toolchain, the same way
# tools/go/build-gorelease.sh builds GORELEASE.ELF. Output: .build/go/GOUPD.ELF
#
# Usage: bash tools/go/build-goupd.sh
#
# Imports are written as `virelai/...` so the host `go test ./...` run (module
# user/go/go.mod) and this GOPATH-mode guest build resolve the same paths.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="goupd"
NAME="${GO_BUILD_NAME:-GOUPD}"
# Gap-layout Go ELFs stream straight from the share into mapped pages and are
# bounded by exec_image_max = 32 MiB on the file and elf.map_max = 64 MiB on
# mapped memory (kernel/src/exec.zig), not the 2 MiB staging buffer. The
# the update stager is a small program — cap at the same explicit 8 MiB budget
# the other Go tools carry.
MAX_BYTES=8388608

log() { printf 'build-goupd: %s\n' "$*"; }

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
( cd "$REPO" && GOOS=virelai GOARCH=arm64 go build -o "$OUT" -ldflags "-s -w" "virelai/$DIR" )

SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
log "wrote $OUT ($SIZE bytes)"
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    log "FAIL: $SIZE bytes exceeds the 8 MiB guest budget ($MAX_BYTES)"
    exit 1
fi
log "size ok (< $MAX_BYTES bytes)"

# Issue #1503: a hand-built ELF with no stamp is indistinguishable from a
# leftover from another branch. Stamp source+elf hashes so class-B setup
# can refuse a mismatch by name instead of booting it.
case "$NAME" in
    GOUPD) ENSURE_GUEST_ELF_ROOT="$REPO" bash "$REPO/tools/go/ensure-guest-elf.sh" stamp "$NAME" "$OUT" ;;
esac
