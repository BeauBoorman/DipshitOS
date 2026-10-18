#!/usr/bin/env bash
#
# build-netdiag.sh -- build the M78a Go network diagnostics.
# Outputs: .build/go/{GONETSTAT,GODNS,GOTRACEROUTE}.ELF
#
# Usage: bash tools/go/build-netdiag.sh
# Requires the provisioned GOOS=virelai fork (`just go-toolchain`).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
MAX_BYTES=2097152 # kernel/src/exec.zig exec_program_max

log() { printf 'build-netdiag: %s\n' "$*"; }
if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

GOPATH_DIR="$REPO/.build/netdiag-gopath"
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
for pair in netstat:GONETSTAT dns:GODNS traceroute:GOTRACEROUTE; do
    dir="${pair%%:*}"
    name="${pair#*:}"
    out="$OUT_DIR/$name.ELF"
    log "building virelai/$dir -> $out"
    (cd "$REPO" && GOOS=virelai GOARCH=arm64 go build -o "$out" -ldflags "-s -w" "virelai/$dir")
    size="$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out")"
    log "wrote $out ($size bytes)"
    if [ "$size" -gt "$MAX_BYTES" ]; then
        log "FAIL: $size bytes exceeds exec_program_max ($MAX_BYTES)"
        exit 1
    fi
    python3 - "$out" "$name" <<'PY'
import struct, sys
path, name = sys.argv[1:]
data = open(path, "rb").read()
phoff, = struct.unpack_from("<Q", data, 0x20)
phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
mem = 0
for i in range(phnum):
    off = phoff + i * phentsize
    p_type, p_flags = struct.unpack_from("<II", data, off)
    if p_type == 1 and p_flags & 2:
        mem = struct.unpack_from("<Q", data, off + 40)[0]
        break
if not mem:
    sys.exit("build-netdiag: %s has no writable PT_LOAD segment" % name)
# Issue #1648: no argv+envp tail-slack assert. Under M71m (#1572) the kernel
# sizes the segment to cover the 4096-B block and initBlocFloor lifts the
# break past it — binary-side page slack never enters the rule.
print("build-netdiag: %s writable PT_LOAD present (memsz %#x)" % (name, mem))
PY
done
