#!/usr/bin/env bash
#
# build-gostore.sh -- build the M110c GOSTORE GUI (user/go/gostore)
# with the GOOS=virelai fork toolchain.
# Output: .build/go/STORE.ELF
#
# Usage: bash tools/go/build-gostore.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="gostore"
NAME="${GO_BUILD_NAME:-GOSTORE}"
# Same budget as STORE (links virelai/store, which parses release.go):
# gap-layout ELFs are bounded by exec_image_max = 32 MiB on the file.
MAX_BYTES=8388608

log() { printf 'build-gostore: %s\n' "$*"; }

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

# ADR 0049 Grounding: gostore links virelai/store, whose sshlib.SHA256Sum /
# sshlib.EncodeHex path must not import crypto/* in non-test files.
if (cd "$REPO/user/go" && grep -rEn '"crypto/' gostore --include='*.go' | grep -v '_test\.go'); then
    log "FAIL: user/go/gostore imports a banned crypto/* package"
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
    log "FAIL: $SIZE bytes exceeds GOSTORE 8 MiB budget ($MAX_BYTES)"
    exit 1
fi
log "size ok (< $MAX_BYTES bytes)"

python3 - "$OUT" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
e_phoff, = struct.unpack_from("<Q", d, 0x20)
e_phentsize, e_phnum = struct.unpack_from("<HH", d, 0x36)
mem = 0
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    p_type, p_flags = struct.unpack_from("<II", d, off)
    if p_type == 1 and (p_flags & 2):  # PT_LOAD, W — the writable segment
        mem = struct.unpack_from("<Q", d, off + 40)[0]  # p_memsz
slack = (-mem) % 4096
need = 0x908
if slack < need:
    sys.exit("build-gostore: writable segment memsz %#x leaves only %#x bytes of "
             "page slack; the kernel's argv+envp protection needs >= %#x or the "
             "runtime's first mmap is refused (grow user/go/gostore argvEnvpGuard)"
             % (mem, slack, need))
print("build-gostore: argv+envp slack ok (memsz %#x, slack %#x bytes)" % (mem, slack))
PY
