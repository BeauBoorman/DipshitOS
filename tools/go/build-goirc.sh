#!/usr/bin/env bash
#
# build-goirc.sh -- build GOIRC.ELF (user/go/goirc, M147a issue #2801)
# with the GOOS=virelai fork toolchain, the same way tools/go/build-goping.sh
# builds the M71n ping. Output: .build/go/GOIRC.ELF
#
# GOIRC ships in image/apps.txt (undocked, caps=file,window,net since the
# M132b reservation) and is staged into the go-irc gate's share by the
# spec's own setup hook. tools/session.sh maps GOIRC.ELF to this builder
# by name convention; ensure-guest-elf.sh stamps the output.
#
# Usage: bash tools/go/build-goirc.sh
#
# Imports are written as `virelai/...` so the host `go test ./...` run
# (module user/go/go.mod) and this GOPATH-mode guest build resolve the
# same paths.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
DIR="goirc"
NAME="${GO_BUILD_NAME:-GOIRC}"
MAX_BYTES=2097152 # kernel/src/exec.zig exec_program_max

log() { printf 'build-goirc: %s\n' "$*"; }

# Match the kernel loader's expectations (build-web.sh's check): static
# AArch64 ET_EXEC at the 0x400000 text aperture, honest segment table.
check_elf() {
    python3 - "$1" <<'PY'
import os, struct, sys
path = sys.argv[1]
size = os.path.getsize(path)
def refuse(reason):
    sys.exit("build-goirc: FAIL: " + reason)
if size > 32 * 1024 * 1024:
    refuse("image_too_large (existing 32 MiB file limit)")
with open(path, "rb") as f:
    head = f.read(16384)
if len(head) < 64 or head[:7] != b"\x7fELF\x02\x01\x01":
    refuse("invalid ELF64 little-endian header")
etype, machine = struct.unpack_from("<HH", head, 16)
entry, phoff = struct.unpack_from("<QQ", head, 24)
phsize, phnum = struct.unpack_from("<HH", head, 54)
if etype != 2 or machine != 183 or phsize != 56 or phnum == 0 or phoff + phsize * phnum > len(head):
    refuse("invalid static AArch64 program-header table")
loads, staged = [], False
for i in range(phnum):
    typ, flags, off, va, _, filesz, memsz, _ = struct.unpack_from("<IIQQQQQQ", head, phoff + i * phsize)
    if typ in (2, 3):
        staged = True
    if typ != 1:
        continue
    if filesz > memsz or off + filesz > size:
        refuse("invalid/truncated load segment")
    loads.append((flags, off, va, filesz, memsz))
if not loads or len(loads) > 3:
    refuse("invalid PT_LOAD count")
if sum(s[3] for s in loads) > 32 * 1024 * 1024:
    refuse("segment_too_large (existing 32 MiB initialized limit)")
if sum(s[4] for s in loads) > 64 * 1024 * 1024:
    refuse("map_too_large (existing 64 MiB mapped limit)")
if loads[0][0] & 2 or not loads[0][2] <= entry < loads[0][2] + loads[0][3]:
    refuse("writable text or invalid entry")
gap = loads[0][2] != 0x400000
for prev, cur in zip(loads, loads[1:]):
    if cur[1] < prev[1] + prev[3] or cur[2] < prev[2] + prev[4]:
        refuse("overlapping file or virtual load ranges")
    gap |= cur[2] != prev[2] + prev[4]
if gap:
    for s in loads:
        if s[2] < 4096 or s[2] % 4096 or s[2] + s[4] > 0x10000000:
            refuse("invalid gap placement")
    if len(loads) > 1 and not loads[-1][0] & 2:
        refuse("read-only data segment")
    if any(s[0] & 2 for s in loads[1:-1]):
        refuse("writable rodata")
PY
}

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

GOPATH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-gopath.XXXXXX")"
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
check_elf "$OUT"
