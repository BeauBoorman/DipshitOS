#!/usr/bin/env bash
#
# build-gotool.sh -- build the GOOS=virelai in-guest toolchain images
# (cmd/compile, cmd/link) with the opt-in `virelaitoolchain` gate, and ASSERT
# every invariant the kernel's loader and the argv+envp block impose, so a
# bad image is refused here by name instead of dying mysteriously in the
# guest. Output: .build/go/{GOCMDCOMPILE,GOCMDLINK}.ELF
#
# Usage: bash tools/go/build-gotool.sh
#
# Why the gate: crypto/internal/fips140 pulls crypto/internal/fips140/drbg
# into both closures, whose entropy_fips140.go declares a 32 MiB .noptrbss
# scratch buffer. When this gate was written the kernel had ONE acceptance
# bound and it summed every PT_LOAD memsz, so the default build was refused
# with segment_too_large. M72a (#1579) split that bound: `load_max` charges
# the INITIALIZED bytes (Σ filesz) and `map_max` (64 MiB) the MAPPED ones —
# these two images' measured Σ memsz (58,254,964 B) now fits both WITH the
# real entropy source, though that has not been booted and is an inference,
# not a result. The gate stays: it is the shape these two closures were
# validated in, and retiring it is its own decision with its own evidence,
# not a side effect of the split.
# The gate excludes that file (and supplies a stub) ONLY for these two
# images; ordinary guest binaries are untouched and keep the real entropy
# source. See ADR 0035 amendment 5.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
TAG="virelaitoolchain"
MAX_BYTES=33554432  # kernel/src/exec.zig exec_image_max (and elf.load_max)
MAP_MAX=67108864    # kernel/src/elf.zig map_max (M72a #1579: the MAPPED bound)

log() { printf 'build-gotool: %s\n' "$*"; }

[ -x "$FORK_DIR/bin/go" ] || {
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
}

export GOROOT="$FORK_DIR"
export PATH="$FORK_DIR/bin:$PATH"
export GOTOOLCHAIN=local
export GO111MODULE=off
export GOFLAGS=
export CGO_ENABLED=0

OUT_DIR="$REPO/.build/go"
mkdir -p "$OUT_DIR"

build() {  # <import-path> <out-name>
    local pkg="$1" name="$2" out="$OUT_DIR/$2.ELF"
    log "building $pkg -> $out (tags: $TAG)"
    GOOS=virelai GOARCH=arm64 go build -tags "$TAG" -o "$out" \
        -ldflags "-s -w" "$pkg"
    log "wrote $name.ELF ($(stat -f%z "$out" 2>/dev/null || stat -c%s "$out") bytes)"
}

build cmd/compile GOCMDCOMPILE
build cmd/link    GOCMDLINK

# The invariants, asserted from the linked ELFs. Every one of these is a rule
# kernel/src/elf.zig's parse_impl enforces. The argv+envp page-slack rule is
# gone with #1648: under M71m (#1572) the kernel packs the 4096-B block at
# align8(mem_size) and sizes the segment to cover it, and the runtime floors
# the sbrk break at memRound(argv_va + 4096) (initBlocFloor), which is
# >= argv_end_va for any image alignment — binary-side page slack never
# enters the rule. Slack is still printed (tools/lib/elf_rules.py reports
# the same figure, not gated).
python3 - "$OUT_DIR/GOCMDCOMPILE.ELF" "$OUT_DIR/GOCMDLINK.ELF" <<'PY'
import struct, sys

MAX_BYTES = 33554432   # exec_image_max / load_max
MAP_MAX   = 67108864   # elf.map_max (M72a #1579: the MAPPED bound)
GAP_MAX   = 0x1000_0000  # elf.gap_base_max
MAX_SEG   = 3            # elf.max_segments

rc = 0
for path in sys.argv[1:]:
    d = open(path, "rb").read()
    entry = struct.unpack_from("<Q", d, 0x18)[0]
    phoff = struct.unpack_from("<Q", d, 0x20)[0]
    phes, pnum = struct.unpack_from("<HH", d, 0x36)
    segs = []
    for i in range(pnum):
        o = phoff + i * phes
        t, fl, off, va, pa, fsz, msz, al = struct.unpack_from("<IIQQQQQQ", d, o)
        if t == 1:
            segs.append(dict(fl=fl, off=off, va=va, fsz=fsz, msz=msz))
    segs.sort(key=lambda s: s["va"])
    name = path.rsplit("/", 1)[-1]
    fails = []
    if len(d) > MAX_BYTES:
        fails.append("file %d > exec_image_max %d" % (len(d), MAX_BYTES))
    if len(segs) > MAX_SEG:
        fails.append("%d PT_LOAD > max_segments %d" % (len(segs), MAX_SEG))
    # M72a (#1579): two bounds, matching the loader's. `load_max` charges the
    # INITIALIZED bytes (Σ filesz) and `MAP_MAX` the MAPPED ones (Σ memsz);
    # charging memsz against the file bound is what made a large `.noptrbss`
    # a refusal.
    total_file = sum(s["fsz"] for s in segs)
    if total_file > MAX_BYTES:
        fails.append("sum filesz %d > load_max %d" % (total_file, MAX_BYTES))
    total = sum(s["msz"] for s in segs)
    if total > MAP_MAX:
        fails.append("sum memsz %d > map_max %d" % (total, MAP_MAX))
    for s in segs:
        if s["va"] + s["msz"] > GAP_MAX:
            fails.append("segment at %#x crosses gap_base_max" % s["va"])
        if s["va"] & 4095:
            fails.append("segment at %#x unaligned" % s["va"])
    if segs and segs[0]["fl"] & 2:
        fails.append("segment 0 is writable")
    for s in segs[1:-1]:
        if s["fl"] & 2:
            fails.append("middle segment at %#x is writable" % s["va"])
    if segs and not (segs[-1]["fl"] & 2):
        fails.append("last segment is not writable")
    if segs and not (segs[0]["va"] <= entry < segs[0]["va"] + segs[0]["fsz"]):
        fails.append("entry %#x not in segment 0 initialized bytes" % entry)
    slack = (-segs[-1]["msz"]) % 4096 if segs else 0
    print("build-gotool: %s segs=%d file=%d memsz=%d (%#x) slack=%d (%#x)"
          % (name, len(segs), len(d), total, total, slack, slack))
    if fails:
        rc = 1
        for f in fails:
            print("build-gotool: FAIL %s: %s" % (name, f))
if rc:
    sys.exit("build-gotool: refusing to stage an image the loader would reject")
print("build-gotool: every loader rule ok")
PY
