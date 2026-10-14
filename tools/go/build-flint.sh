#!/usr/bin/env bash
#
# build-flint.sh -- build the M103 FLINT source-control CLI (user/go/flint,
# ADR 0049) with the GOOS=virelai fork toolchain.
# Output: .build/go/FLINT.ELF
#
# Usage: bash tools/go/build-flint.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="flint"
NAME="${GO_BUILD_NAME:-FLINT}"
# Gap-layout Go ELFs stream straight from the share into mapped pages and are
# bounded by exec_image_max = 32 MiB on the file and elf.map_max = 64 MiB on
# mapped memory (kernel/src/exec.zig:16-19,138), not the 2 MiB staging buffer.
# FLINT imports go/parser + go/ast + go/token; cap at an explicit 8 MiB budget
# (ADR 0049 Grounding).
MAX_BYTES=8388608

log() { printf 'build-flint: %s\n' "$*"; }

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

# ADR 0049 Grounding: FLINT uses sshlib.SHA256Sum / sshlib.EdSign /
# sshlib.EdVerify in-tree and must not import crypto/* in non-test files.
if (cd "$REPO/user/go" && grep -rEn '"crypto/' flint --include='*.go' | grep -v '_test\.go'); then
    log "FAIL: user/go/flint imports a banned crypto/* package"
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
    log "FAIL: $SIZE bytes exceeds FLINT 8 MiB budget ($MAX_BYTES)"
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
    sys.exit("build-flint: writable segment memsz %#x leaves only %#x bytes of "
             "page slack; the kernel's argv+envp protection needs >= %#x or the "
             "runtime's first mmap is refused (grow user/go/flint argvEnvpGuard)"
             % (mem, slack, need))
print("build-flint: argv+envp slack ok (memsz %#x, slack %#x bytes)" % (mem, slack))
PY
