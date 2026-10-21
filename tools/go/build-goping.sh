#!/usr/bin/env bash
#
# build-goping.sh -- build the M71n Go ping (user/go/ping) with the GOOS=virelai
# fork toolchain, the same way tools/go/build-gosh.sh builds the M68a shell.
# Output: .build/go/GOPING.ELF
#
# Usage: bash tools/go/build-goping.sh
#
# GOPING.ELF is the successor to Zig PING.BIN (deleted by #1573): the same CLI,
# the same grep-able markers and the same 0/1/2/3 exit contract, over the same
# ICMP syscall seam (slots 59/60). It is a host-share ELF (like GOTOP.ELF /
# GOFETCH.ELF), not an image-baked Zig program, so a spec stages it.
#
# Imports are written as `virelai/...` so the host `go test ./...` run (module
# user/go/go.mod) and this GOPATH-mode guest build resolve the same paths.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="ping"
NAME="${GO_BUILD_NAME:-GOPING}"
MAX_BYTES=2097152 # kernel/src/exec.zig exec_program_max

log() { printf 'build-goping: %s\n' "$*"; }

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
