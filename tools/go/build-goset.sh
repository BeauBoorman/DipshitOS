#!/usr/bin/env bash
#
# build-goset.sh -- build the M71f (#1565) Go settings panel (user/go/goset,
# the app; its codec is the shared virelai/settings package)
# with the GOOS=virelai fork toolchain, the same way tools/go/build-note.sh
# builds the M66c notepad. Output: .build/go/GOSET.ELF
#
# GOSET.ELF retires the Zig panel SETTINGS.BIN (user/src/settings_panel.zig,
# deleted): on the default Go seat the panel you launch is this one, and it
# writes the same schema-v2 /host/SETTINGS.TXT the seat and the kernel read.
#
# Usage: bash tools/go/build-goset.sh
#
# Imports are written as `virelai/...` so the host `go test ./...` run (module
# user/go/go.mod) and this GOPATH-mode guest build resolve the same paths.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="goset"
NAME="${GO_BUILD_NAME:-GOSET}"
MAX_BYTES=2097152 # kernel/src/exec.zig exec_program_max

log() { printf 'build-goset: %s\n' "$*"; }

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

# -gcflags=all=-l: GOSET sits within a few KB of exec_program_max, and the
# M128d profile view tipped the .text run past a 64KB ELF segment boundary —
# every page-sized step costs ~64KB of file for a few hundred bytes of code.
# Disabling inlining buys ~90KB of headroom at no ABI cost (the guest ABI is
# the ELF entry point, not call shapes); a settings panel trades nothing.
log "building virelai/$DIR -> $OUT"
( cd "$REPO" && GOOS=virelai GOARCH=arm64 go build -o "$OUT" -gcflags=all=-l -ldflags "-s -w" "virelai/$DIR" )

SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
log "wrote $OUT ($SIZE bytes)"
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    log "FAIL: $SIZE bytes exceeds exec_program_max ($MAX_BYTES); the kernel loader will refuse it"
    exit 1
fi
log "size ok (< $MAX_BYTES bytes)"
