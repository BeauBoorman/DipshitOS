#!/usr/bin/env bash
#
# build-go.sh -- build GOOS=virelai programs with the fork toolchain
# (issue #1163). Runs the host make.bash pass on first use (the
# cross-std pass is GOVIRELAI_STD=1 opt-in; see the pass-1 comment), then
# links the named program as a static ET_EXEC at the kernel's fixed text
# aperture (0x400000), DWARF+symtab stripped to fit the 1 MiB staging
# bound (kernel exec.zig exec_program_max).
#
# Usage: bash tools/go/build-go.sh [program.go ...]
#   Builds tools/go/hello.go by default. Output: <program>.ELF next to the
#   source, or into $GO_BUILD_OUT when set (the gate copies from there).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
BOOTSTRAP="${GOROOT_STOCK:-/opt/homebrew/Cellar/go/1.27.1/libexec}"

log() { printf 'build-go: %s\n' "$*"; }

[ -d "$FORK_DIR/src/runtime" ] || bash "$REPO/tools/go/apply.sh" --fork-dir "$FORK_DIR"

# Pass 1: host toolchain (built from the PATCHED tree, so bin/go already
# knows GOOS=virelai and its cross tool binaries target arm64). Programs
# that import runtime only need this pass — packages compile on demand
# into the build cache. Pass 2 (a full `GOOS=virelai make.bash` std
# install) is phase 2: it needs the syscall/os port layer (the wasip1
# mirror) and is opt-in via GOVIRELAI_STD=1.
if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "building host toolchain (make.bash pass 1)"
    ( cd "$FORK_DIR/src" && GOROOT_BOOTSTRAP="$BOOTSTRAP" ./make.bash ) >&2
fi

if [ "${GOVIRELAI_STD:-0}" = "1" ]; then
    log "installing full std for virelai/arm64 (phase 2: needs the syscall/os port)"
    ( cd "$FORK_DIR/src" && GOROOT_BOOTSTRAP="$BOOTSTRAP" GOOS=virelai GOARCH=arm64 ./make.bash ) >&2
fi

export GOROOT="$FORK_DIR"
export PATH="$FORK_DIR/bin:$PATH"
export GOTOOLCHAIN=local   # never silently swap back to a stock toolchain
export GOFLAGS=
export GO111MODULE=off
export GOPATH="${TMPDIR:-/tmp}/go-virelai-gopath"
export CGO_ENABLED=0

mkdir -p "$GOPATH"
# A fixture may import the shared guest SDK (virelai/vi): link user/go into
# GOPATH as `virelai`, exactly like tools/go/build-web.sh, so GOPATH-mode
# guest builds resolve the same import path the host module does.
mkdir -p "$GOPATH/src"
ln -sfn "$REPO/user/go" "$GOPATH/src/virelai"
out_dir="${GO_BUILD_OUT:-$REPO/.build/go}"
mkdir -p "$out_dir"
rc=0
for prog in "${@:-$REPO/tools/go/hello.go}"; do
    # GOPATH mode needs an absolute FILE path (a relative one is parsed as
    # an import path).
    prog="$(cd "$(dirname "$prog")" && pwd)/$(basename "$prog")"
    base="$(basename "${prog%.go}")"
    # Gate-canonical output names: the class-B specs stage
    # .build/go/GOHELLO.ELF / GOARGS.ELF into the guest share, so `just
    # go-toolchain` must land those exact names (GO_BUILD_NAME overrides).
    case "$base" in
        hello)      base="GOHELLO" ;;
        goargs)     base="GOARGS" ;;
        goroutines) base="GOROUT" ;;
        smpscale)   base="GOSCALE" ;;
        gostress)   base="GOSTRESS" ;;
        gopanic)    base="GOPANIC" ;;
        gowin)      base="GOWIN" ;;
        gonet)      base="GONET" ;;
        govinet)    base="GOVINET" ;;
        govidns)    base="GOVIDNS" ;;
        gobig)      base="GOBIG" ;;
        # M72a (#1579): the >32 MiB-`.noptrbss` fixture for the loader's
        # mapped-memory bound (`go-hello` run 11).
        goloadbss)  base="GOLOADBSS" ;;
        goread)     base="GOREAD" ;;
        # M179a (#3147): the net-throughput bench fixture — dials the
        # --net relay and moves a fixed 4 MiB stream rx or tx.
        gonetrate)  base="GONETRATE" ;;
        # M119c (#2487): the seat-mailbox burst-absorption fixture.
        mburst)     base="GOMBURST" ;;
        gosyscall)  base="GOSYSCALL" ;;
        # #2354: the region-straddle large-read fixture (go-hello run 13).
        gobigread)  base="GOBIGREAD" ;;
        # M70c-S2 (#1544): the in-guest build-loop driver.
        selfhost)   base="GOSELFHOST" ;;
    esac
    out="$out_dir/${GO_BUILD_NAME:-$base}.ELF"
    # The gap loader gives a program a FIXED text aperture, so image size is
    # a correctness constraint: GONET/GOVINET/GOVIDNS (bigger programs than
    # the other fixtures) link with symbols stripped (-s -w) to stay inside
    # the text gap. < GO_LDFLAGS_VALUE defaults to the historical "-w".
    strip="-w"
    case "$base" in
        # GOBIG is the M70c-K (#1504) >8 MiB fixture: fully stripped, and
        # still past the bound on its initialized payload alone (8.0 MiB of
        # .data), so the "stripped Go ELF" in that card's acceptance is
        # literal.
        GONET | GOVINET | GOVIDNS | GOBIG) strip="-s -w" ;;
        # M70c (#1455): the share-read measurement fixture. It links the whole
        # `vi` surface, which is what puts it in this class.
        # M119c (#2487): GOMBURST also links `vi` (IpcSend/WmctlSeatPid) —
        # same class.
        GOREAD | GOMBURST | GONETRATE) strip="-s -w" ;;
        # M70c-S1P (#1525): the syscall-layer fixture — the std `syscall`
        # package for GOOS=virelai, which is smaller than `vi` but not small.
        GOSYSCALL) strip="-s -w" ;;
        # #2354: os/fmt surface like GOSYSCALL's — same class.
        GOBIGREAD) strip="-s -w" ;;
        # M70c-S2 (#1544): the driver links `vi` (Exec/Wait/Probe) and `vsys`,
        # the same order of surface GOREAD links.
        GOSELFHOST) strip="-s -w" ;;
    esac
    log "building $prog -> $out (ldflags: $strip)"
    GOOS=virelai GOARCH=arm64 go build -o "$out" \
        -ldflags "${GO_LDFLAGS_VALUE:-$strip}" "$prog" || rc=1

    # Issue #1163 phase 2: the kernel's gap loader maps a GOOS=virelai
    # program at FIXED vaddrs (text 0x10000..0x80000, rodata ..0x110000,
    # data 0x110000..). A program whose text or rodata outgrows its gap
    # makes the Go linker SHIFT the later segments; the process then loads
    # but misbehaves on target. Catch that at BUILD time, not as a mystery
    # boot: report which segment overflowed and by how much.
    if [ -f "$out" ]; then
        guard="$(python3 - "$out" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
phoff = struct.unpack_from("<Q", d, 32)[0]
phes = struct.unpack_from("<H", d, 54)[0]
phnum = struct.unpack_from("<H", d, 56)[0]
segs = []
for i in range(phnum):
    o = phoff + i * phes
    t, fl, off, va, pa, fsz, msz, al = struct.unpack_from("<IIQQQQQQ", d, o)
    if t == 1:
        segs.append((va, fsz))
segs.sort()
bad = []
if segs and segs[0][0] != 0x10000:
    bad.append("text base 0x%x != 0x10000" % segs[0][0])
if segs and segs[0][0] + segs[0][1] > 0x80000:
    bad.append("text ends 0x%x > 0x80000" % (segs[0][0] + segs[0][1]))
if len(segs) >= 2 and segs[1][0] != 0x80000:
    bad.append("rodata base 0x%x != 0x80000" % segs[1][0])
if len(segs) >= 2 and segs[1][0] + segs[1][1] > 0x110000:
    bad.append("rodata ends 0x%x > 0x110000" % (segs[1][0] + segs[1][1]))
if len(segs) >= 3 and segs[2][0] != 0x110000:
    bad.append("data base 0x%x != 0x110000" % segs[2][0])
print("; ".join(bad))
PY
)"
        if [ -n "$guard" ]; then
            # Kept as a WARNING: the overflow is a real anomaly (every
            # known-good fixture fits), but making it fatal would block a
            # fixture whose on-target behaviour is still under
            # investigation. GO_STRICT_LAYOUT=1 promotes it to an error.
            log "WARN: $(basename "$out") does not sit at the kernel's fixed gap vaddrs: $guard"
            log "      the Go linker shifted a segment. This was measured on a build that"
            log "      failed on target, but it did NOT prove causal (removing the text"
            log "      overflow did not change the symptom), so treat it as a smell to"
            log "      check, not a diagnosis. Shrink with -s -w / fewer stdlib imports."
            if [ "${GO_STRICT_LAYOUT:-0}" = "1" ]; then rc=1; fi
        else
            log "gap layout ok: $(basename "$out")"
        fi
    fi
done
exit "$rc"
