#!/usr/bin/env bash
#
# build-store.sh -- build the M101c STORE install-seam CLI (user/go/store/main)
# with the GOOS=virelai fork toolchain.
# Output: .build/go/STORE.ELF
#
# Usage: bash tools/go/build-store.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="store/main"
NAME="${GO_BUILD_NAME:-STORE}"
# Same budget as FLINT (imports go/parser through virelai/flint/parser):
# gap-layout ELFs are bounded by exec_image_max = 32 MiB on the file.
MAX_BYTES=8388608

log() { printf 'build-store: %s\n' "$*"; }

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

# ADR 0049 Grounding: STORE uses sshlib.SHA256Sum / sshlib.EncodeHex
# in-tree and must not import crypto/* in non-test files.
if (cd "$REPO/user/go" && grep -rEn '"crypto/' store --include='*.go' | grep -v '_test\.go'); then
    log "FAIL: user/go/store imports a banned crypto/* package"
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
    log "FAIL: $SIZE bytes exceeds STORE 8 MiB budget ($MAX_BYTES)"
    exit 1
fi
log "size ok (< $MAX_BYTES bytes)"

# Issue #1648: no argv+envp tail-slack assert here. Under M71m (#1572) the
# kernel packs the 4096-B block at align8(mem_size) and sizes the segment
# to cover it; the runtime floors the sbrk break at memRound(argv_va +
# 4096) (initBlocFloor), which is >= argv_end_va for any image alignment.
# Binary-side page slack never enters the rule (same removal as
# build-gosh.sh).
