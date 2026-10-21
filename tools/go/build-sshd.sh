#!/usr/bin/env bash
#
# build-sshd.sh -- build the M70g G1 in-guest SSH-2 server (user/go/sshd)
# with the GOOS=virelai fork toolchain. Output: .build/go/GOSSHD.ELF
#
# Usage: bash tools/go/build-sshd.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="sshd"
NAME="${GO_BUILD_NAME:-GOSSHD}"
MAX_BYTES=2097152 # kernel/src/exec.zig exec_program_max

log() { printf 'build-sshd: %s\n' "$*"; }

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

# Issue #1648: no argv+envp tail-slack assert here. Under M71m (#1572) the
# kernel packs the 4096-B block at align8(mem_size) and sizes the segment
# to cover it; the runtime floors the sbrk break at memRound(argv_va +
# 4096) (initBlocFloor), which is >= argv_end_va for any image alignment.
# Binary-side page slack never enters the rule (same removal as
# build-gosh.sh).

# Issue #1503: stamp source+elf hashes so class-B setup can refuse a
# leftover GOSSHD.ELF by name (same exists-only staging as GOSH, PR #1508).
case "$NAME" in
    GOSH|GOSSHD) ENSURE_GUEST_ELF_ROOT="$REPO" bash "$REPO/tools/go/ensure-guest-elf.sh" stamp "$NAME" "$OUT" ;;
esac
