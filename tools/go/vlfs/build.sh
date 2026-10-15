#!/usr/bin/env bash
# Build the host-side VLFS formatter/checker into .build/go/mkfs.vlfs.
# Usage: bash tools/go/vlfs/build.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
REPO="$(cd ../../.. && pwd)"
OUT="$REPO/.build/go/mkfs.vlfs"
mkdir -p "$(dirname "$OUT")"
GOTOOLCHAIN=local go build -o "$OUT" .
echo "build-vlfs: wrote $OUT"
