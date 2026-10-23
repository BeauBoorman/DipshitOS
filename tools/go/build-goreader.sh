#!/usr/bin/env bash
#
# build-goreader.sh -- build the M143a Go document reader (user/go/goreader)
# with the GOOS=virelai fork toolchain, the same way tools/go/build-goview.sh
# builds the image viewer. Output: .build/go/GOREADER.ELF
#
# GOREADER.ELF is the Document mime's registered handler (image/apps.txt
# `opens=document`, user/go/mime), so it is a host-share ELF like every
# other Go app, not an in-image Zig program.
#
# Usage: bash tools/go/build-goreader.sh
#
# Imports are written as `virelai/...` so the host `go test ./...` run
# (module user/go/go.mod) and this GOPATH-mode guest build resolve the
# same paths.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="goreader"
NAME="${GO_BUILD_NAME:-GOREADER}"
MAX_BYTES=$((32 * 1024 * 1024)) # M72a load_max (exec_image_max): initialized ELF bytes.

log() { printf 'build-goreader: %s\n' "$*"; }

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

GOPATH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-gopath.XXXXXX")"
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
    log "FAIL: $SIZE bytes exceeds M72a load_max ($MAX_BYTES)"
    exit 1
fi
log "size ok (< $MAX_BYTES bytes)"
