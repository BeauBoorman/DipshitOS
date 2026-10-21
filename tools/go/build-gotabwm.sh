#!/usr/bin/env bash
#
# build-gotabwm.sh -- build the Go window manager (user/go/gotabwm) with
# the GOOS=virelai fork toolchain, the same way tools/go/build-tabapp.sh builds
# the demo tab app. Output: .build/go/GOTABWM.ELF
#
# M57a–c: seat + own windows + Zig-app hosting. M62b (#1400): in-process
# tab strip (open / close / focus) painted onto the compose-N scanout.
#
# Usage: bash tools/go/build-gotabwm.sh
#
# Imports are written as `virelai/...` so the host `go test ./...` run (module
# user/go/go.mod) and this GOPATH-mode guest build resolve the same paths.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="gotabwm"
NAME="${GO_BUILD_NAME:-GOTABWM}"
MAX_BYTES=33554432 # kernel/src/exec.zig exec_image_max — GOOS=virelai
# ELFs are gap-layout and stream past the 2 MiB staging bound (M70c-K
# #1504); the loader's real acceptance bound is the image one.

log() { printf 'build-gotabwm: %s\n' "$*"; }

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
    log "FAIL: $SIZE bytes exceeds exec_image_max ($MAX_BYTES); the kernel loader will refuse it"
    exit 1
fi
log "size ok (< $MAX_BYTES bytes)"
