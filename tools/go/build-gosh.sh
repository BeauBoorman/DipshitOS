#!/usr/bin/env bash
#
# build-gosh.sh -- build the M68a Go shell (user/go/sh) with the GOOS=virelai
# fork toolchain, the same way tools/go/build-goterm.sh builds the M58c
# terminal. Output: .build/go/GOSH.ELF
#
# Usage: bash tools/go/build-gosh.sh
#
# Imports are written as `virelai/...` so the host `go test ./...` run (module
# user/go/go.mod) and this GOPATH-mode guest build resolve the same paths.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="sh"
NAME="${GO_BUILD_NAME:-GOSH}"
MAX_BYTES=2097152 # kernel/src/exec.zig exec_program_max

log() { printf 'build-gosh: %s\n' "$*"; }

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

# Issue #1648: the argv+envp tail-slack assert that used to live here is
# gone with its rule. It encoded the pre-M71m 2304-B block (need 0x908) and
# the stale "grow user/go/sh argvEnvpGuard" remedy. Under M71m (#1572) the
# block is 4096 B, exec.zig packs it at align8(mem_size) AND sizes the
# segment to cover it, and the runtime floors the sbrk break at
# memRound(argv_va + 4096) (overlay/runtime/os_virelai.go initBlocFloor),
# which is >= argv_end_va for any image alignment. Binary-side page slack
# never enters the rule; the invariant lives in exec.zig (cover), in the
# host test beside process.zig's mmap_collides, and in the live-sh* gates
# that boot a real GOSH through it. (The REAL trap that day was fork/overlay
# drift, caught now by tools/env-check.sh -- same issue.)

# Issue #1503: a hand-built ELF with no stamp is indistinguishable from a
# leftover from another branch. Stamp source+elf hashes so class-B setup
# can refuse a mismatch by name instead of booting it.
case "$NAME" in
    GOSH|GOSSHD) ENSURE_GUEST_ELF_ROOT="$REPO" bash "$REPO/tools/go/ensure-guest-elf.sh" stamp "$NAME" "$OUT" ;;
esac
