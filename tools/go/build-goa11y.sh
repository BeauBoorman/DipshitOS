#!/usr/bin/env bash
#
# build-goa11y.sh -- build GOA11Y.ELF, the M177b (#3143) accessibility
# outline reader (user/go/goa11y: kind-16 focus poll + the /host/A11Y.<win>
# staged file painted as an indented list) with the GOOS=virelai fork
# toolchain. Output: .build/go/GOA11Y.ELF
#
# Usage: bash tools/go/build-goa11y.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="goa11y"
NAME="${GO_BUILD_NAME:-GOA11Y}"
MAX_BYTES=2097152 # kernel/src/exec.zig exec_program_max

log() { printf 'build-goa11y: %s\n' "$*"; }

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
    log "FAIL: $SIZE bytes exceeds exec_program_max ($MAX_BYTES); the kernel loader will refuse it"
    exit 1
fi
log "size ok (< $MAX_BYTES bytes)"
