#!/usr/bin/env bash
#
# apply.sh -- build/patch a GOOS=virelai gc toolchain fork (issue #1163).
#
# The fork is a COPY of a stock Go distribution (not a git checkout of
# golang/go — the go1.27.x release tags carry only the runtime+stdlib
# tree; the toolchain sources ship in the distribution). This script:
#   1. copies the stock GOROOT into $FORK_DIR (once),
#   2. copies the overlay files from tools/go/overlay/ into it,
#   3. applies the small source edits (declarative, idempotent), including
#      reversing leftover phase-0a proc.go deltas on an existing fork (M65c),
#   4. commits the patch as a git delta for reviewability.
#
# Re-running is safe: existing overlay/edit state is detected and kept.
#
# Usage:  bash tools/go/apply.sh [--fork-dir DIR]
#   --fork-dir DIR   fork location (default ../go-virelai next to the
#                    primary workspace checkout)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${FORK_DIR:-$(dirname "$REPO")/go-virelai}"
SRC_GOOS="virelai"
GO_VERSION="1.27.1"

if [ "${1:-}" = "--fork-dir" ]; then FORK_DIR="${2:?}"; shift 2; fi
[ $# -eq 0 ] || { echo "usage: bash tools/go/apply.sh [--fork-dir DIR]" >&2; exit 2; }

log() { printf 'apply: %s\n' "$*"; }

# --- 1. fresh copy of the stock distribution ---------------------------
if [ ! -d "$FORK_DIR" ]; then
    STOCK="${GOROOT_STOCK:-/opt/homebrew/Cellar/go/${GO_VERSION}/libexec}"
    [ -d "$STOCK/src/cmd/dist" ] || STOCK="$(go env GOROOT)"
    [ -d "$STOCK/src/cmd/dist" ] || { echo "apply: no stock GOROOT with src/cmd/dist found" >&2; exit 1; }
    log "copying stock distribution $STOCK -> $FORK_DIR"
    mkdir -p "$FORK_DIR"
    rsync -a --exclude bin --exclude pkg "$STOCK/" "$FORK_DIR/"
    ( cd "$FORK_DIR" && git init -q && git add -A &&
      git commit -qm "go${GO_VERSION} distribution baseline (pre-GOOS=${SRC_GOOS})" )
fi

F="$FORK_DIR/src"
[ -f "$F/runtime/time_nofake.go" ] || { echo "apply: $F does not look like a Go GOROOT src tree" >&2; exit 1; }

edits=0
have() { grep -qF "$2" "$1" 2>/dev/null; }

# tag_has <file> <term> -- does the file's //go:build line mention <term>?
#
# The tag guards below must ask the build line ITSELF, never a fixed head(1)
# window. sys_cloexec.go is the case that proved it: its //go:build sits on
# line 8 behind a two-line comment, so the old `head -6` guard never saw the
# `|| virelai` it had just appended and added another on EVERY run — the
# shared fork's line had grown to 29 copies of the term. Idempotence is a
# property this script advertises (tools/go/README.md) and the M70c cards
# depend on, so the guard has to read exactly the line it edits.
tag_has() { grep -m1 '^//go:build' "$1" 2>/dev/null | grep -q -- "$2"; }

# tag_dedupe <file> -- collapse terms repeated by that old fixed-window guard,
# so one run of this script REPAIRS a fork an earlier revision polluted rather
# than only declining to add more. Purely textual and confined to the
# //go:build line: "|| virelai || virelai ..." becomes "|| virelai".
tag_dedupe() {
    gsed -i \
        -e '/^\/\/go:build/ s/\(|| virelai\)\( || virelai\)\+/\1/g' \
        -e '/^\/\/go:build/ s/\(\&\& !virelai\)\( \&\& !virelai\)\+/\1/g' \
        "$1" 2>/dev/null || true
}

# --- 2. overlay files (new, GOOS-gated) --------------------------------
# gostalgia/, gostalgia-mods/ and charm-mods/ are stage overlays:
# build-gostalgia.sh / build-charmhello.sh apply them onto staged trees
# in .build/, never onto the fork. Copied into src/ they both fail
# make.bash (`go_bootstrap install std` compiles them) and collide with
# the stage at package resolution (ambiguous import: gostalgia/cmd/*
# found in two modules — observed breaking #2634 cold and warm).
log "copying overlay files"
( cd "$REPO/tools/go/overlay" && find . -type f \
    ! -path "./gostalgia/*" ! -path "./gostalgia-mods/*" ! -path "./charm-mods/*" | while read -r f; do
    mkdir -p "$FORK_DIR/src/$(dirname "$f")"
    cp "$f" "$FORK_DIR/src/$f"
done )

# --- 2b. prune stale overlay files --------------------------------------
# The copy above is additive, so a file an earlier revision of the overlay
# ADDED and a later one deleted lingers in the fork forever — where it either
# shadows the current code or, as one did, collides with a stock declaration
# (overlay/os/sigpipe_virelai.go vs os/file_unix.go's `func sigpipe()`). The
# prune is deliberately narrow: it deletes only files matching the overlay's
# own naming convention (*_virelai*), and only inside directories the overlay
# mirrors, so nothing else in the distribution can be touched by it.
( cd "$REPO/tools/go/overlay" && find . -type d | while read -r d; do
    rel_dir="${d#./}"; [ "$d" = "." ] && rel_dir="."
    for f in "$FORK_DIR/src/$rel_dir"/*_virelai*.go "$FORK_DIR/src/$rel_dir"/*_virelai*.s; do
        [ -e "$f" ] || continue
        rel="${f#"$FORK_DIR/src/"}"
        if [ ! -e "$REPO/tools/go/overlay/$rel" ]; then
            rm -f "$f"; log "pruned stale overlay file $rel"
        fi
    done
done )

# --- 2c. remove leaked stage overlays ------------------------------------
# An earlier revision of the copy above mirrored gostalgia/ and
# gostalgia-mods/ into the fork too. Those trees are never fork files —
# only the build scripts' stages consume them — so an existing polluted
# fork is healed here by deleting them outright (the narrow *_virelai*
# prune cannot reach them: the stage overlays carry other names).
for d in gostalgia gostalgia-mods charm-mods; do
    if [ -d "$FORK_DIR/src/$d" ]; then
        rm -rf "$FORK_DIR/src/$d"
        log "removed leaked stage overlay src/$d"
    fi
done

# --- 3a. internal/syslist/syslist.go: KnownOS --------------------------
if ! have "$F/internal/syslist/syslist.go" '"virelai"'; then
    gsed -i 's/\t"wasip1":    true,/\t"wasip1":    true,\n\t"virelai":   true,/' "$F/internal/syslist/syslist.go"
    edits=$((edits+1)); log "patched internal/syslist/syslist.go (KnownOS)"
fi

# --- 3b. cmd/dist/build.go: okgoos + cgoEnabled ------------------------
if ! have "$F/cmd/dist/build.go" '"virelai",'; then
    gsed -i 's/^\t"wasip1",$/\t"wasip1",\n\t"virelai",/' "$F/cmd/dist/build.go"
    edits=$((edits+1)); log "patched cmd/dist/build.go (okgoos)"
fi
if ! have "$F/cmd/dist/build.go" '"virelai/arm64"'; then
    gsed -i 's/^\t"wasip1\/wasm":     false,$/\t"wasip1\/wasm":     false,\n\t"virelai\/arm64":  false,/' "$F/cmd/dist/build.go"
    edits=$((edits+1)); log "patched cmd/dist/build.go (cgoEnabled)"
fi

# --- 3c. cmd/internal/objabi/head.go: virelai -> ELF (Hlinux) ----------
if ! have "$F/cmd/internal/objabi/head.go" 'case "virelai":'; then
    gsed -i 's/^\tcase "wasip1":$/\tcase "virelai":\n\t\t*h = Hlinux\n\tcase "wasip1":/' "$F/cmd/internal/objabi/head.go"
    edits=$((edits+1)); log "patched cmd/internal/objabi/head.go (HeadType)"
fi

# --- 3d. runtime/mem_sbrk.go: the sbrk memory platform -----------------
if ! tag_has "$F/runtime/mem_sbrk.go" virelai; then
    gsed -i 's#^//go:build plan9 || wasm$#//go:build plan9 || wasm || virelai#' "$F/runtime/mem_sbrk.go"
    edits=$((edits+1)); log "patched runtime/mem_sbrk.go (build tag)"
fi

# Only the successful sbrk branch owns fresh zero padding. Keep the ordinary
# free/trim and sysFreeOS shrink clears; see os_virelai.go's zero invariant.
# Match both edits before writing, refusing unknown/partially patched source.
padding="$(python3 - "$F/runtime/mem_sbrk.go" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()
changes = [
    ("""func memFree(ap unsafe.Pointer, n uintptr) {
	n = memRound(n)
	memclrNoHeapPointers(ap, n)""",
     """func memFree(ap unsafe.Pointer, n uintptr) {
	memFreeWithClear(ap, n, true)
}

// memFreeWithClear links a block whose non-header bytes must be zero.
// Only virelai's fresh sbrk alignment padding may skip the clear.
//
//go:systemstack
func memFreeWithClear(ap unsafe.Pointer, n uintptr, clear bool) {
	n = memRound(n)
	if clear {
		memclrNoHeapPointers(ap, n)
	}"""),
    ("""			// Free the area we skipped over for alignment.
			memFree(r, l)
			memCheck()""",
     """			// Free the area we skipped over for alignment.
			if GOOS == "virelai" {
				// sbrk returns zero bytes, including a cleared shrink.
				memFreeWithClear(r, l, false)
			} else {
				memFree(r, l)
			}
			memCheck()"""),
]
old = all(s.count(before) == 1 and after not in s for before, after in changes)
# The 3d2 unmap patch rewrites memFreeWithClear's clear-branch afterwards,
# so the already-patched state is marked by the function + call site, not
# the exact clear-branch text this block writes.
new = ("func memFreeWithClear(" in s
       and "memFreeWithClear(r, l, false)" in s
       and all(before not in s for before, _ in changes))
if not (old or new):
    sys.exit("apply: SourceDrift: runtime/mem_sbrk.go alignment padding")
if old:
    for before, after in changes:
        s = s.replace(before, after, 1)
    p.write_text(s)
print("patched" if old else "clean")
PYEOF
)"
if [ "$padding" = "patched" ]; then
    edits=$((edits+1)); log "patched runtime/mem_sbrk.go (virelai fresh alignment padding)"
fi

# --- 3d2. runtime/mem_sbrk.go: a free/unused hands the phys back, not a --
# free-list link. Stock sbrk keeps every released page mapped — cleared or
# scavenged, never handed back — so an exec'd child's footprint is its
# cumulative peak, and the M112a fleet's driver (~95 MiB) plus a link
# child (~133 MiB) drains the 256 MiB guest pool mid-run (#2430). On
# virelai every release path (the free-list insert, the break-shrink, the
# scavenger's sysUnused) calls virMunmap: the kernel drops the phys while
# the freed VA keeps its mmap region record, so a later touch/sysUsed
# demand-faults a fresh zero page back in and the reuse paths are
# unchanged. The memclr goes too: the page is gone, and writing zeros
# into it would only fault a replacement straight back in.
memreturn="$(python3 - "$F/runtime/mem_sbrk.go" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()
changes = [
    ("""func memFreeWithClear(ap unsafe.Pointer, n uintptr, clear bool) {
	n = memRound(n)
	if clear {
		memclrNoHeapPointers(ap, n)
	}""",
     """func memFreeWithClear(ap unsafe.Pointer, n uintptr, clear bool) {
	n = memRound(n)
	if GOOS == "virelai" {
		// Return the freed span's phys to the kernel NOW (sys_munmap):
		// the freed VA keeps its mmap region record, so a later touch
		// demand-faults a fresh zero page back in — the free-list reuse
		// path is unchanged while the span's pages stop being held. The
		// memclr is dropped: the page is gone, and writing zeros into it
		// would only fault a replacement straight back in (the demand
		// refill is zero by construction).
		virMunmap(ap, n)
	} else if clear {
		memclrNoHeapPointers(ap, n)
	}"""),
    ("""			// Address range being freed is at the end of memory,
			// so record a new lower value for end of memory.
			// Can't actually shrink address space because segment is shared.
			memclrNoHeapPointers(v, n)
			bloc -= n""",
     """			// Address range being freed is at the end of memory,
			// so record a new lower value for end of memory.
			// Can't actually shrink address space because segment is shared.
			// virelai: the memclr is replaced by an unmap — the phys
			// returns to the pool and a re-sbrk re-maps it demand-zero.
			if GOOS == "virelai" {
				virMunmap(v, memRound(n))
			} else {
				memclrNoHeapPointers(v, n)
			}
			bloc -= n"""),
    ("""func sysUnusedOS(v unsafe.Pointer, n uintptr) {
}""",
     """func sysUnusedOS(v unsafe.Pointer, n uintptr) {
	// virelai: the scavenger's "unused" hint becomes a real release —
	// the scavenged span's phys returns to the kernel (sys_munmap) while
	// the VA keeps its mmap region record, so a later sysUsed/touch
	// demand-faults a fresh zero page back in. Without this, stock sbrk
	// held every scavenged page mapped — a child's footprint stayed at
	// its cumulative peak and the fleet's aggregate drained the pool.
	if GOOS == "virelai" {
		systemstack(func() {
			virMunmap(v, memRound(n))
		})
	}
}"""),
]
old = all(s.count(before) == 1 and after not in s for before, after in changes)
new = all(s.count(after) == 1 and before not in s for before, after in changes)
if not (old or new):
    sys.exit("apply: SourceDrift: runtime/mem_sbrk.go virelai unmap")
if old:
    for before, after in changes:
        s = s.replace(before, after, 1)
    p.write_text(s)
print("patched" if old else "clean")
PYEOF
)"
if [ "$memreturn" = "patched" ]; then
    edits=$((edits+1)); log "patched runtime/mem_sbrk.go (virelai releases unmap phys)"
fi

# --- 3d3. runtime/mgcpacer.go: default GOGC + GOMEMLIMIT for the 256 MiB -
# guest. Stock Go runs GC off (GOGC=100 → ~2x-live heap, no GOMEMLIMIT cap)
# — an exec'd child's footprint then rides ~2x its live set, and the M112a
# fleet's link children (~56k pages) OOM-killed mid-fleet at free=0 (#2430).
# On virelai the defaults tighten: GOGC=30 keeps the heap near its live set
# (smaller allocation bursts), and GOMEMLIMIT caps heap-in-use at 190 MiB so
# a child's heap + driver + statics stay inside the ~64k-page pool.
memlimit="$(python3 - "$F/runtime/mgcpacer.go" <<'PYEOF'
import sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()
changes = [
    ("""func readGOGC() int32 {
	p := gogetenv("GOGC")
	if p == "off" {
		return -1
	}
	if n, err := strconv.ParseInt(p, 10, 32); err == nil {
		return int32(n)
	}
	return 100
}""",
     """func readGOGC() int32 {
	p := gogetenv("GOGC")
	if p == "off" {
		return -1
	}
	if n, err := strconv.ParseInt(p, 10, 32); err == nil {
		return int32(n)
	}
	if GOOS == "virelai" {
		// virelai: the 256 MiB guest's pool is ~64k pages, so an exec'd
		// child can't afford the default GC target's 2x-live heap —
		// a link child at ~56k pages OOM-killed mid-fleet (#2430).
		// A low GOGC keeps the heap tight against its live set (the
		// GC runs at ~20% growth instead of 100%), so the child's
		// footprint stays near what it actually needs.
		return 20
	}
	return 100
}"""),
    ("""func readGOMEMLIMIT() int64 {
	p := gogetenv("GOMEMLIMIT")
	if p == "" || p == "off" {
		return math.MaxInt64
	}""",
     """func readGOMEMLIMIT() int64 {
	p := gogetenv("GOMEMLIMIT")
	if p == "" || p == "off" {
		if GOOS == "virelai" {
			// virelai: the 256 MiB guest's whole page pool is ~64k
			// pages; a resident driver plus an exec'd child sharing it
			// must not grow past ~200 MiB of heap-in-use or the demand-
			// fault path drains to free=0 and the child dies 139 (#2430 —
			// observed: link children at ~56k pages OOM-killing mid-fleet).
			// The cap bounds heap-in-use (stacks, runtime and the binary's
			// statics are extra), so children collect to stay under it.
			return 200 << 20
		}
		return math.MaxInt64
	}"""),
]
old = all(s.count(before) == 1 and after not in s for before, after in changes)
new = all(s.count(after) == 1 and before not in s for before, after in changes)
if not (old or new):
    sys.exit("apply: SourceDrift: runtime/mgcpacer.go virelai GC limits")
if old:
    for before, after in changes:
        s = s.replace(before, after, 1)
    p.write_text(s)
print("patched" if old else "clean")
PYEOF
)"
if [ "$memlimit" = "patched" ]; then
    edits=$((edits+1)); log "patched runtime/mgcpacer.go (virelai GOGC/GOMEMLIMIT)"
fi

# --- 3e. runtime/lock_sema.go: spinning semaphores (no OS primitives) --
if ! tag_has "$F/runtime/lock_sema.go" virelai; then
    gsed -i 's#^//go:build aix || darwin || netbsd || openbsd || plan9 || solaris || windows$#//go:build aix || darwin || netbsd || openbsd || plan9 || solaris || windows || virelai#' "$F/runtime/lock_sema.go"
    edits=$((edits+1)); log "patched runtime/lock_sema.go (build tag)"
fi

# --- 3f. runtime/proc.go: retire leftover ADR 0026 D5 single-M deltas --
# ADR 0027 D5 / M65c (#1441): #1214 deleted patch_proc.py and stopped
# *applying* the 0a gates, but never reversed them. An existing
# ../go-virelai fork therefore stays single-M (haveSysmon off, canCreateM,
# template thread skipped, spare-M handoffs dropped, dolock/dounlock
# bookkeeping-only, stopm yields) until wiped. Invert 32400aa0's 3f +
# patch_proc.py in place. Idempotent: a stock or already-restored proc.go
# (no "virelai") is a no-op. Fresh copies never have these deltas.
#
# Exact reverses: haveSysmon → `GOARCH != "wasm"`; drop canCreateM;
# startTemplateThread / dolockOSThread / dounlockOSThread wasm-only;
# startTheWorld spare-M `else { newm }`; drop startm's `!canCreateM`
# early return; drop stopm's virelai osyield. After this, proc.go has
# zero virelai mentions — threads ride overlay newosproc (slot 73) and
# lock_sema parks on slot 74 via os_virelai.go.
restored="$(python3 - "$F/runtime/proc.go" <<'PYEOF'
import re
import sys

p = sys.argv[1]
s = open(p).read()
if "virelai" not in s:
    print("clean")
    raise SystemExit(0)

n = 0

def note(name):
    global n
    n += 1
    print("restore_proc: reversed " + name, file=sys.stderr)

s2, c = re.subn(
    r'^const haveSysmon = GOARCH != "wasm" && GOOS != "virelai".*$',
    'const haveSysmon = GOARCH != "wasm"',
    s,
    count=1,
    flags=re.M,
)
if c:
    s = s2
    note("haveSysmon")

# patch_proc.py splices canCreateM after the haveSysmon *anchor*
# (no comment), so the 3f comment hitchhikes onto the canCreateM line.
s2, c = re.subn(
    r'^const canCreateM = GOARCH != "wasm" && GOOS != "virelai".*\n',
    "",
    s,
    count=1,
    flags=re.M,
)
if c:
    s = s2
    note("canCreateM")

old = """func startTemplateThread() {
	if GOARCH == "wasm" || GOOS == "virelai" { // no threads on wasm or virelai yet
		return
	}"""
new = """func startTemplateThread() {
	if GOARCH == "wasm" { // no threads on wasm yet
		return
	}"""
if old in s:
    s = s.replace(old, new, 1)
    note("startTemplateThread")

old = """		} else if canCreateM {
			// Start M to run P.  Do not start another M below.
			newm(nil, p, -1)
		} else {
			// issue #1163 phase 0a: no kernel thread_create yet; the
			// single-P invariant keeps this path unreachable.
			p.m = 0
		}"""
new = """		} else {
			// Start M to run P.  Do not start another M below.
			newm(nil, p, -1)
		}"""
if old in s:
    s = s.replace(old, new, 1)
    note("startTheWorld")

old = """	nmp := mget()
	if nmp == nil && !canCreateM {
		// issue #1163 phase 0a: no kernel thread_create yet. Drop the
		// handoff; the single-M scheduler retries on its next pass.
		releasem(mp)
		return
	}
	if nmp == nil {
		// No M is available, we must drop sched.lock and call newm."""
new = """	nmp := mget()
	if nmp == nil {
		// No M is available, we must drop sched.lock and call newm."""
if old in s:
    s = s.replace(old, new, 1)
    note("startm")

old = """func dolockOSThread() {
	if GOARCH == "wasm" || GOOS == "virelai" {
		return // no threads on wasm or virelai yet (issue #1163 phase 0a)
	}"""
new = """func dolockOSThread() {
	if GOARCH == "wasm" {
		return // no threads on wasm yet
	}"""
if old in s:
    s = s.replace(old, new, 1)
    note("dolockOSThread")

old = """func dounlockOSThread() {
	if GOARCH == "wasm" || GOOS == "virelai" {
		return // no threads on wasm or virelai yet (issue #1163 phase 0a)
	}"""
new = """func dounlockOSThread() {
	if GOARCH == "wasm" {
		return // no threads on wasm yet
	}"""
if old in s:
    s = s.replace(old, new, 1)
    note("dounlockOSThread")

old = """func stopm() {
	if GOOS == "virelai" {
		// issue #1163 phase 0a: the single M must never park — nothing
		// else exists to wake it (no sysmon, no second thread). Yield to
		// the kernel scheduler and let the caller retry findRunnable.
		// Removed with slot 72.
		osyield()
		return
	}
	gp := getg()"""
new = """func stopm() {
	gp := getg()"""
if old in s:
    s = s.replace(old, new, 1)
    note("stopm")

if "virelai" in s:
    i = s.index("virelai")
    sys.exit(
        "restore_proc: leftover virelai in proc.go after known reverses:\n"
        + s[max(0, i - 80) : i + 80]
    )
open(p, "w").write(s)
print("retired")
PYEOF
)"
if [ "$restored" = "retired" ]; then
    edits=$((edits+1)); log "restored runtime/proc.go (retired leftover 0a single-M deltas, M65c)"
elif [ "$restored" != "clean" ]; then
    echo "apply: unexpected restore_proc status: $restored" >&2
    exit 1
fi

# --- 3f2. runtime/tls_arm64.h: the virelai TLS case --------------------
# Pure-Go arm64 keeps g in R28 (load_g/save_g return immediately for
# non-cgo), so the MRS below never executes — but the file must assemble.
# Map virelai onto the linux-style TPIDR_EL0 macro.
if ! have "$F/runtime/tls_arm64.h" 'GOOS_virelai'; then
    python3 - "$F/runtime/tls_arm64.h" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
if "GOOS_virelai" not in s:
    anchor = "#ifdef GOOS_linux\n#define TLS_linux\n#endif"
    assert anchor in s
    s = s.replace(anchor, "#ifdef GOOS_virelai\n#define TLS_linux\n#endif\n" + anchor, 1)
    open(p, "w").write(s)
PYEOF
    edits=$((edits+1)); log "patched runtime/tls_arm64.h (virelai -> TPIDR_EL0, unused)"
fi

# --- 3g. exclude virelai from generic-tag files it must not match ------
# Appends "&& !virelai" to the //go:build line; each reason inline.
vir_exclude() {  # <file> <reason>
    tag_dedupe "$F/runtime/$1"
    if ! tag_has "$F/runtime/$1" virelai; then
        gsed -i '0,/^\/\/go:build /s#^//go:build \(.*\)$#//go:build \1 \&\& !virelai#' "$F/runtime/$1"
        edits=$((edits+1)); log "patched runtime/$1 (exclude virelai: $2)"
    fi
}
# mem_nonsbrk.go declares isSbrkPlatform=false for everything non-sbrk.
vir_exclude mem_nonsbrk.go "sbrk platform"
# stubs2.go declares exit/write1/exitThread/usleep (+read/open/madvise)
# bodyless — os_virelai.go provides the ones it needs.
vir_exclude stubs2.go "GOOS-level exit/write1/exitThread"
# stubs3.go + timestub2.go declare nanotime1/walltime as gojs
# host-imports (GOOS=js machinery) — virelai provides its own.
vir_exclude stubs3.go "js nanotime1 wasmimport"
vir_exclude timestub2.go "js walltime wasmimport"

# --- 3g. internal/platform/zosarch.go: List + distInfo rows ------------
if ! have "$F/internal/platform/zosarch.go" '{"virelai", "arm64"}'; then
    gsed -i 's|^\t{"wasip1", "wasm"},$|\t{"virelai", "arm64"},\n\t{"wasip1", "wasm"},|' "$F/internal/platform/zosarch.go"
    gsed -i 's|^\t{"wasip1", "wasm"}:     {},$|\t{"virelai", "arm64"}:   {},\n\t{"wasip1", "wasm"}:     {},|' "$F/internal/platform/zosarch.go"
    edits=$((edits+1)); log "patched internal/platform/zosarch.go"
fi

# --- 3g2. the syscall/os port (issue #1525, M70c-S1P) ------------------
# Appends "|| virelai" to a //go:build line so a stock file that is already
# written against a GOOS-provided syscall surface compiles for virelai too.
# Each entry must be justified: the file is stock POSIX-shaped code whose
# calls land in overlay/syscall/syscall_virelai.go|fs_virelai.go, so no
# behaviour is being invented here — only the tag. A file whose helpers the
# port supplies as stubs (e.g. no net, no pidfd) says so at that stub.
vir_include() {  # <path-under-src> <reason>
    tag_dedupe "$F/$1"
    if ! tag_has "$F/$1" virelai; then
        gsed -i '0,/^\/\/go:build /s#^//go:build \(.*\)$#//go:build \1 || virelai#' "$F/$1"
        edits=$((edits+1)); log "patched $1 (include virelai: $2)"
    fi
}
# The exact reverse of vir_include, for a file an earlier revision DID
# include: its helpers are ones this port must supply itself (a runtime
# linkname target, a syscall-number table), so selecting it twice would be a
# redeclaration. Reversing keeps apply.sh the single source of truth for the
# fork's tags instead of depending on which revision ran last.
vir_exclude() {  # <path-under-src> <why this port cannot use it>
    tag_dedupe "$F/$1"
    if tag_has "$F/$1" '|| virelai'; then
        gsed -i '0,/^\/\/go:build /s#^//go:build \(.*\) || virelai$#//go:build \1#' "$F/$1"
        edits=$((edits+1)); log "reverted $1 (virelai must not select it: $2)"
    fi
}
# dirent.go: the Dirent parse helpers (readInt + ParseDirent) over THIS
# GOOS's Dirent, which is the kernel's own 40-byte sys_dir_list row.
vir_include syscall/dirent.go "dirent parse helpers"
# timestruct.go: Timespec/Timeval <-> nanoseconds, pure arithmetic.
vir_include syscall/timestruct.go "timespec arithmetic"
# env_unix.go: Setenv/Unsetenv/Clearenv over the runtime's env block
# (issue #1226 gave the guest a real envp; this exposes it as os.Environ).
vir_include syscall/env_unix.go "environment block"

# --- 3g3. internal/poll for virelai (issue #1525, M70c-S1P) --------------
# `os` is a thin shell over internal/poll's FD; none of poll's platform
# files select for an unknown GOOS, so the package has no FD type at all.
# These are the same files wasip1 compiles (fd_wasip1.go stands in for
# fd_unixjs.go there because WASI lacks dup): virelai takes the POSIX
# shapes, since the ADR 0007 slots are descriptor-based.
vir_include internal/poll/fd_posix.go          "FD lock/close helpers"
# fd_unix.go is the FD struct + Read/Write/Close over syscall.Read/Write.
vir_include internal/poll/fd_unix.go           "FD core"
# fd_unixjs.go supplies SysFile, dupCloseOnExecOld (ForkLock+Dup),
# Fchdir and Seek — the four things fd_wasip1.go reimplements for WASI.
vir_include internal/poll/fd_unixjs.go         "SysFile/dup/fchdir/seek"
vir_include internal/poll/fd_poll_runtime.go   "poller binding (runtime_poll*)"
vir_include internal/poll/fd_fsync_posix.go    "fd sync"
vir_include internal/poll/fstatat_unix.go      "fstatat on an FD"
vir_include internal/poll/errno_unix.go        "errno translation"
vir_include internal/poll/hook_unix.go         "CloseFunc/AcceptFunc hooks"
vir_include internal/poll/sys_cloexec.go       "accept() cloexec fallback"

# --- 3g4. time's TZ database plumbing (issue #1525) --------------------
# sys_unix.go: the open/read/close/seek helpers zoneinfo_read.go calls.
vir_include time/sys_unix.go "zoneinfo file access"
# zoneinfo_unix.go: platformZoneSources + initLocal. The guest has no TZ
# database in any of the search paths, so initLocal falls back to UTC —
# which is the guest's actual clock (ADR 0021: no RTC, uptime seconds).
vir_include time/zoneinfo_unix.go "platform TZ lookup"

# --- 3g5. os for virelai (issue #1525, M70c-S1P) -----------------------
# The unix-tagged half of `os`: path resolution, file handles over
# internal/poll, rename/unlink/mkdir, the Root API, dirent walking. Each
# call lands in the overlay syscall package; nothing is reimplemented.
vir_include os/dir_unix.go        "directory iteration"
vir_include os/exec_posix.go      "Process basics"
vir_include os/exec_unix.go       "fork/exec plumbing"
vir_include os/file_open_unix.go  "openFileNolog"
vir_include os/file_posix.go      "File helpers"
vir_include os/file_unix.go       "File core"
vir_include os/path_unix.go       "path handling"
vir_include os/pidfd_other.go     "pidfd stubs (no pidfd slot)"
vir_include os/removeall_at.go    "RemoveAll via openat"
vir_include os/removeall_unix.go  "removeAllFrom"
vir_include os/root_openat.go     "Root API over openat"
vir_include os/root_unix.go       "Root API"
vir_include os/stat_unix.go       "Stat/Lstat/Fstat"
vir_include os/zero_copy_posix.go "copy_file_range fallback"
# eloop_other.go: how a failed O_NOFOLLOW open is recognised as ELOOP.
vir_include os/eloop_other.go    "ELOOP classification"
# statat_unix.go: File.lstatatNolog, the per-entry stat a directory walk
# does (the rows carry a name, not a FileInfo).
vir_include os/statat_unix.go    "per-entry lstat during readdir"
# sys_unix.go: the constants each unix GOOS answers about itself
# (supportsCloseOnExec). Stock says true, and true is right here for a
# consequence-free reason: the port accepts O_CLOEXEC and ignores it because
# nothing at EL0 inherits a descriptor table, and os only consults this
# constant to decide whether it must simulate cloexec another way.
vir_include os/sys_unix.go "supportsCloseOnExec"
# internal/filepathlite: os's own path plumbing (Separator, Base, Dir) — the
# filepath and os packages both read it instead of duplicating the rules.
vir_include internal/filepathlite/path_unix.go "path separators/rules"

vir_exclude internal/syscall/unix/fcntl_unix.go "port supplies Fcntl (no runtime.fcntl here)"
vir_exclude internal/syscall/unix/nonblocking_unix.go "port supplies IsNonblock"
vir_exclude internal/syscall/unix/utimes.go "port supplies Utimensat (linkname target absent)"

# internal/syscall/unix: the helpers `os` imports from there (Faccessat,
# Nofollow). The *at() family, Fcntl and IsNonblock come from the overlay's
# own at_virelai.go|fcntl_virelai.go instead, because the stock files route
# them through runtime.fcntl or a per-GOOS syscall-number table this port
# does not have. net.go is deliberately absent: it exists for `net`, which
# has no slots here yet.
vir_include internal/syscall/unix/constants.go        "R_OK/W_OK/X_OK + NoFollowErrno"
vir_include internal/syscall/unix/eaccess.go          "Eaccess via faccessat"
vir_include internal/syscall/unix/nofollow_posix.go   "ELOOP for O_NOFOLLOW"
# net.go: the eight Inet4/Inet6 wrappers internal/poll's FD calls on the
# socket methods it compiles. They forward to the overlay's Recvfrom/Sendto/
# Recvmsg/SendmsgN (all ENOSYS), so the wrappers exist because poll names them
# whether or not a socket can exist here.
vir_include internal/syscall/unix/net.go              "Inet4/Inet6 poll wrappers"

# --- 3g6. the rest of std, so `go build std` closes (issue #1525) ------
# Measured after the first pass: six packages refused, and four of them
# wanted nothing but the tag (the other two are `net` and its socktest
# helper, which have no slots to call at all — a net port is its own arc,
# it is not a missing include).
vir_include path/filepath/path_unix.go        "Separator/Join/Abs/SplitList"
vir_include os/exec/lp_unix.go                "LookPath + ErrNotFound (search works; spawn still refuses)"
vir_include os/signal/signal_unix.go          "numSig/signum (no delivery; watchers see nothing)"
vir_include os/user/lookup_unix.go            "/etc/passwd-shaped lookup (guest has none: honest error)"
vir_include os/user/listgroups_unix.go        "group listing on the same file"
vir_include crypto/internal/sysrand/rand_getrandom.go "read() over unix.GetRandom"
# GetRandom itself comes from the overlay (getrandom_virelai.go) rather than
# the stock Linux file, which reaches for a raw SYS_GETRANDOM trap number.
vir_exclude internal/syscall/unix/getrandom.go "Linux trap numbers; port supplies GetRandom"

# --- 3g6b. net for virelai (issue #2029, M95 prerequisite) ---------------
# `net` needs a platform surface: netFD, the dial/listen hooks the shared
# dial.go names, resolver methods, and the sockopt/file/interface leaves.
# This port compiles the stock POSIX *plumbing* — the same files js and
# wasip1 select — and supplies the leaves itself in overlay/net/, where
# every one refuses: there are no socket slots to call. The js/wasip1 fake
# fabric (net_fake.go/fd_fake.go) was evaluated and rejected: it implements
# a WORKING in-memory loopback, and the card requires TCP loopback,
# listeners and unix sockets to refuse. So the dial/listen plumbing below
# is stock — argument validation, OpError/AddrError wrapping, resolver
# ordering — and the refusal lives at socket(), the leaf all of it reaches.
vir_include net/ipsock_posix.go     "family pick, sockaddr<->Addr, probe (sysSocket refuses)"
vir_include net/tcpsock_posix.go    "TCP dial/listen/conn plumbing; refuses at socket()"
vir_include net/udpsock_posix.go    "UDP plumbing; refuses at socket()"
vir_include net/iprawsock_posix.go  "raw-IP plumbing; refuses at socket()"
vir_include net/unixsock_posix.go   "unix-socket plumbing; refuses at socket()"
vir_include net/sockaddr_posix.go   "the sockaddr interface + addrFunc"
vir_include net/port_unix.go        "service-name port table (goLookupPort)"
vir_include net/lookup_unix.go      "resolver methods; every lookup ends at a refused dial"
vir_include net/error_posix.go      "wrapSyscallError"
vir_include net/error_unix.go       "isConnError errno classification"
vir_include net/sock_stub.go        "maxListenerBacklog (advisory; listen refuses anyway)"
vir_include net/unixsock_readmsg_other.go "no cmsghdr here: readMsgFlags=0"
vir_include net/cgo_stub.go         "cgoAvailable=false; the cgo resolver never runs"
# socktest is `net`'s test helper — the second of the two std holdouts the
# 3g6 comment names. Its switch/sys pair wrap the same socket syscalls the
# overlay now refuses, so it compiles the honest way too (test-only code;
# nothing it wraps can run).
vir_include net/internal/socktest/switch_unix.go "Sockets switch; wraps refusing syscalls"
vir_include net/internal/socktest/sys_unix.go    "socket wrappers over the ENOSYS surface"

# --- 3g7. os/dir_unix.go's zero-inode skip (issue #1525) ---------------
# dir_unix.go drops a directory row whose inode is 0 unless the GOOS is
# linux or wasip1, because some filesystems report 0 for real files. This
# filesystem is one of them: an EL0 directory row (sys_dir_list) carries a
# name, a size and an is-dir bit and NO inode number, so the port reports 0
# honestly (overlay/os/dirent_virelai.go) and has to be added to that list —
# the same reason wasip1 is in it.
if ! have "$F/os/dir_unix.go" 'runtime.GOOS != "virelai"'; then
    gsed -i 's#runtime.GOOS != "wasip1" {#runtime.GOOS != "wasip1" \&\& runtime.GOOS != "virelai" {#' "$F/os/dir_unix.go"
    edits=$((edits+1)); log "patched os/dir_unix.go (zero-inode skip includes virelai)"
fi

# --- 3g8. exclude the FIPS 140 DRBG scratch buffer for virelai ----------
# Why a tag edit and not a capability: cmd/compile links
# crypto/internal/fips140 -> ... -> crypto/internal/fips140/drbg, and
# drbg/entropy_fips140.go declares a 32 MiB scratch buffer unconditionally
# for every non-wasm platform:
#
#     var memory entropy.ScratchBuffer    exactly 33,554,432 B, .noptrbss
#
# Upstream calls the buffer lazy (it is written only when the FIPS module
# runs), but that laziness is not this kernel's: the gap loader allocates and
# zero-fills EVERY mapped page before EL0 runs, so the 32 MiB scratch buffer
# is 32 MiB of guest RAM in whatever image carries it. What the kernel
# bounded, when this gate was written, was the sum of every PT_LOAD memsz
# against a single 32 MiB acceptance bound — so cmd/compile was refused with
# segment_too_large. Measured: 58,254,964 B of memsz, of which 33,554,432 is
# this one object; without it the image is 23.56 MiB. M72a (#1579) split that
# bound (`load_max` on the INITIALIZED bytes, `map_max` = 64 MiB on the
# MAPPED ones), so this image now fits with the real entropy source; the
# gate is unchanged here and its retirement is a separate decision.
#
# This follows upstream's own answer, but GATED. The same file's comment
# says the buffer "usually doesn't cost much, except on Wasm, due to the way
# the linear memory works. FIPS 140-3 mode is not supported on Wasm, so we
# just use a build tag to exclude it. (Could also exclude other platforms
# that does not support FIPS 140-3 mode, but as the BSS variable doesn't
# cost much, don't bother.)"
#
# The obvious generalisation — exclude it for GOOS=virelai outright — is
# WRONG here, and the difference matters. wasm's exclusion is a GOOS-wide
# property of wasm; a virelai guest is instead expected to keep a WORKING
# crypto/rand, since M47/M67 landed TLS and DNS on it. Neutering the entropy
# source GOOS-wide to shrink two toolchain binaries would regress that. So
# the pair of edits below is scoped to an opt-in build tag that ONLY the
# cmd/compile and cmd/link recipe passes: the default GOOS=virelai path keeps
# entropy_fips140.go — the real source and its scratch buffer — and nothing
# about ordinary guest binaries changes.
#
# Measured before choosing that shape (go list -deps): crypto/rand and
# crypto/tls are ABSENT from both closures while fips140/drbg is present,
# reached through crypto/internal/fips140 rather than through crypto/rand:
#
#     cmd/compile: crypto/rand=0  crypto/tls=0  fips140/drbg=1
#     cmd/link:    crypto/rand=0  crypto/tls=0  fips140/drbg=1
#
# So the DRBG is dead weight in exactly these two images, and the stub below
# is not on their happy path. If it ever were called it PANICS — a loud
# failure, never a silent degradation.
#
# The exclusion has to be paired with a stub, or the package has no
# getEntropy at all: entropy_fips140.go is the ONLY definition of it (rand.go
# calls it at lines 26 and 73), which is what the GOOS-wide first attempt
# surfaced:
#
#     rand.go:26:21: undefined: getEntropy
#     rand.go:73:16: undefined: getEntropy
#
# The stub can NOT be upstream's entropy_wasm.go, and the reason is worth
# recording because it looks like it should work. A Go file's GOOS/GOARCH
# SUFFIX and its //go:build line are BOTH enforced — they AND together — so
# entropy_wasm.go's `_wasm` NAME pins it to wasm whatever its build line
# says. Widening that line to include virelai is compiled by nothing and
# leaves getEntropy undefined. Measured, not assumed: with the widened line
# and -tags virelaitoolchain the build still reported
#
#     rand.go:26:21: undefined: getEntropy
#
# The stub is therefore its own overlay file, drbg/entropy_virelai.go, whose
# `_virelai` suffix supplies the GOOS half and whose //go:build line supplies
# the opt-in half. Only cmd/compile and cmd/link are built with that tag.
#
# Self-healing, as the helpers above are: an earlier revision of this block
# applied a GOOS-wide `&& !virelai` here and a (useless) `|| virelai` on
# entropy_wasm.go, so both are normalised back FIRST and cannot compound.
drbg_dir="$F/crypto/internal/fips140/drbg"
drbg_entropy="$drbg_dir/entropy_fips140.go"
drbg_stub="$drbg_dir/entropy_wasm.go"
# entropy_fips140.go: strip only the LEGACY bare form. The clause added below
# is written `!(virelai && virelaitoolchain)`, where a paren follows the `!`,
# so this pattern cannot match it — that is exactly why it is parenthesised
# rather than left bare. Stripping the gated form here would make apply.sh
# oscillate: remove, re-add, report an edit on every run.
gsed -i '/^\/\/go:build/ s/ \&\& !virelai//g' "$drbg_entropy"
# entropy_wasm.go: BOTH forms go, because nothing is added back here — so
# there is no oscillation to risk.
gsed -i -e '/^\/\/go:build/ s/ || (virelai \&\& virelaitoolchain)//g' \
        -e '/^\/\/go:build/ s/ || virelai//g' "$drbg_stub"
if ! tag_has "$drbg_entropy" 'virelaitoolchain'; then
    gsed -i '0,/^\/\/go:build /s#^//go:build \(.*\)$#//go:build \1 \&\& !(virelai \&\& virelaitoolchain)#' "$drbg_entropy"
    edits=$((edits+1)); log "patched crypto/internal/fips140/drbg/entropy_fips140.go (toolchain-only exclude: 32 MiB FIPS scratch buffer vs load_max)"
fi

# --- 3h. runtime/netpoll.go: enable the poller CORE for virelai --------
# Issue #1163 phase 2. The platform-independent poller core (netpollblock/
# unblock, netpollready, the deadline machinery) is tagged
# "unix || (js && wasm) || wasip1 || windows"; virelai must join that set or
# the overlay's netpoll platform hooks have no core to plug into. The core
# itself is stock — this only widens the build tag.
if ! tag_has "$F/runtime/netpoll.go" virelai; then
    gsed -i 's#^//go:build unix || (js && wasm) || wasip1 || windows$#//go:build unix || (js \&\& wasm) || wasip1 || windows || virelai#' "$F/runtime/netpoll.go"
    edits=$((edits+1)); log "patched runtime/netpoll.go (enable poller core for virelai)"
fi

# --- 4. commit the delta ----------------------------------------------
if [ "$edits" -gt 0 ]; then
    ( cd "$FORK_DIR" && git add -A &&
      git commit -qm "GOOS=virelai: overlay + wiring (issue #1163 phase 0a)" )
fi
log "fork ready at $FORK_DIR ($edits new edits)"
log "next: GOROOT_BOOTSTRAP=<stock go> bash $FORK_DIR/src/make.bash"
log "      GOOS=$SRC_GOOS GOARCH=arm64 bash $FORK_DIR/src/make.bash"
