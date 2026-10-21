#!/usr/bin/env bash
# Build the bounded boot supervisor with the pinned BSD-3-Clause Go fork.
# Optional argument: install into an explicitly selected host-share directory.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
test -x "$FORK_DIR/bin/go" || { echo "build-init: provision the Go fork first" >&2; exit 1; }
GOPATH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-init-gopath.XXXXXX")"
trap 'rm -rf "$GOPATH_DIR"' EXIT
mkdir -p "$GOPATH_DIR/src" "$REPO/.build/go"
ln -s "$REPO/user/go" "$GOPATH_DIR/src/virelai"
export GOROOT="$FORK_DIR" GOTOOLCHAIN=local GO111MODULE=off GOFLAGS=
export GOPATH="$GOPATH_DIR" CGO_ENABLED=0
OUT="$REPO/.build/go/INIT.ELF"
"$FORK_DIR/bin/go" version
GOOS=virelai GOARCH=arm64 "$FORK_DIR/bin/go" build -ldflags "-s -w" -o "$OUT" virelai/init
SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
test "$SIZE" -le 2097152 || { echo "build-init: $SIZE exceeds 2097152 bytes" >&2; exit 1; }
echo "build-init: INIT.ELF $SIZE bytes"
if [ "$#" -gt 0 ]; then
    test "$#" -eq 1 || exit 2
    mkdir -p "$1/INIT"
    cp "$OUT" "$1/INIT.ELF"
    # Never replace a user's manifest during a rebuild.
    if [ ! -e "$1/INIT/SERVICES.JSON" ]; then
        cp "$REPO/user/go/init/SERVICES.JSON" "$1/INIT/SERVICES.JSON"
    fi
fi
