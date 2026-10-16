#!/usr/bin/env bash
#
# build-godiff.sh -- build the M107e capstone diff utility (user/go/godiff,
# issue #2322) with the GOOS=virelai fork toolchain.
# Output: .build/go/GODIFF.ELF
#
# Usage: bash tools/go/build-godiff.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="godiff"
NAME="${GO_BUILD_NAME:-GODIFF}"
# Gap-layout Go ELFs stream straight from the share into mapped pages and are
# bounded by exec_image_max = 32 MiB on the file and elf.map_max = 64 MiB on
# mapped memory (kernel/src/exec.zig:16-19,138), not the 2 MiB staging buffer.
MAX_BYTES=33554432

log() { printf 'build-godiff: %s\n' "$*"; }

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

# The kernel packs argv+envp (0x900 bytes) into the writable segment's tail and
# protects it against the sbrk break (mmap_collides, issue #1214); the runtime's
# break starts at the page-rounded bss end, so the bss must end at least 0x908
# bytes below the segment's page end or mallocinit dies on its first mmap.
# Assert it from the linked ELF, naming the padding var (argvEnvpGuard).
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
need = 0x908  # the packed block (0x900) plus its 8-byte alignment step
if slack < need:
    sys.exit("build-godiff: writable segment memsz %#x leaves only %#x bytes of "
             "page slack; the kernel's argv+envp protection needs >= %#x or the "
             "runtime's first mmap is refused (grow user/go/godiff argvEnvpGuard)"
             % (mem, slack, need))
print("build-godiff: argv+envp slack ok (memsz %#x, slack %#x bytes)" % (mem, slack))
PY
