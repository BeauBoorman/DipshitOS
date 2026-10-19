#!/usr/bin/env bash
# Build the M129b (#2611) spawn-storm fixture with the repository-pinned Go
# fork. Output .build/go/GOSTORM.ELF, limited to the usual 2 MiB
# application budget.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
if [ ! -x "$FORK_DIR/bin/go" ]; then
    echo "build-storm: missing pinned fork at $FORK_DIR/bin/go" >&2
    echo "provision with tools/go/apply.sh and tools/go/build-go.sh first" >&2
    exit 1
fi
GOPATH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-storm.XXXXXX")"
trap 'rm -rf "$GOPATH_DIR"' EXIT
mkdir -p "$GOPATH_DIR/src"
ln -s "$REPO/user/go" "$GOPATH_DIR/src/virelai"
export GOROOT="$FORK_DIR" GOPATH="$GOPATH_DIR"
export PATH="$FORK_DIR/bin:$PATH"
export GOTOOLCHAIN=local GO111MODULE=off GOFLAGS= CGO_ENABLED=0
mkdir -p "$REPO/.build/go"
OUT="$REPO/.build/go/GOSTORM.ELF"
GOOS=virelai GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o "$OUT" virelai/stormfixture
SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
if [ "$SIZE" -gt 2097152 ]; then
    echo "build-storm: $SIZE bytes exceeds the 2097152-byte application budget" >&2
    exit 1
fi
echo "build-storm: wrote $OUT ($SIZE bytes)"
