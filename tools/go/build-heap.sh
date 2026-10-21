#!/usr/bin/env bash
# Build the M94d library-backed HEAP viewer and bounded HEAPFIX workload.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
[ -x "$FORK_DIR/bin/go" ] || { echo "build-heap: provision the Go fork first"; exit 1; }
GOPATH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-heap-gopath.XXXXXX")"
trap 'rm -rf "$GOPATH_DIR"' EXIT
mkdir -p "$GOPATH_DIR/src" "$REPO/.build/go"
ln -s "$REPO/user/go" "$GOPATH_DIR/src/virelai"
export GOROOT="$FORK_DIR" PATH="$FORK_DIR/bin:$PATH" GOTOOLCHAIN=local
export GO111MODULE=off GOFLAGS= GOPATH="$GOPATH_DIR" CGO_ENABLED=0
for pair in HEAP:heap/cmd HEAPFIX:heapfixture HEAPBUDG:heapfixture/budget; do
    name="${pair%%:*}"
    dir="${pair#*:}"
    out="$REPO/.build/go/$name.ELF"
    GOOS=virelai GOARCH=arm64 go build -o "$out" -ldflags "-s -w" "virelai/$dir"
    size="$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out")"
    echo "build-heap: $name.ELF $size bytes"
    [ "$size" -le 2097152 ] || { echo "build-heap: exceeds exec_program_max"; exit 1; }
done
