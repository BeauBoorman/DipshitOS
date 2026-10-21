#!/usr/bin/env bash
#
# build-pulse.sh -- build PULSE.ELF, the Go seat's Charm TUI system monitor
# (issue #1609), with the GOOS=virelai fork. Charm stays in the Go module
# cache: no vendor tree, README dump, or host ANSI renderer is copied into
# this repository.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
NAME="${GO_BUILD_NAME:-PULSE.ELF}"
BT_VERSION="v2.0.9"
# M168c: lipgloss v2 builds for GOOS=virelai unmodified — the v1 import
# pulled termenv, go-isatty and x/cellbuf into the closure and needed two
# Virelai platform shims; v2's colours are color.Color, so none of that
# staging survives. Do not use its `compat` package: it queries
# stdin/stdout for the background colour at package init.
LG_VERSION="v2.0.6"
MAX_BYTES=$((32 * 1024 * 1024)) # M72a load_max: initialized ELF bytes.

log() { printf 'build-pulse: %s\n' "$*"; }

# MIT/BSD attribution for the Charm modules linked into the ELF lives in
# user/go/pulse/THIRD-PARTY.txt (sources stay in the module cache, so the
# notice has to ship separately). A version bump without re-resolving that
# file must fail here, not silently ship stale notices.
if ! grep -q "bubbletea/v2 ${BT_VERSION}" "$REPO/user/go/pulse/THIRD-PARTY.txt"; then
    log "FAIL: THIRD-PARTY.txt does not pin Bubble Tea ${BT_VERSION}; re-resolve and update it"
    exit 1
fi
if ! grep -q "lipgloss/v2 ${LG_VERSION}" "$REPO/user/go/pulse/THIRD-PARTY.txt"; then
    log "FAIL: THIRD-PARTY.txt does not pin lipgloss v2 ${LG_VERSION}; re-resolve and update it"
    exit 1
fi

if [ ! -x "$FORK_DIR/bin/go" ]; then
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
fi

export GOROOT="$FORK_DIR"
export PATH="$FORK_DIR/bin:$PATH"
export GOTOOLCHAIN=local
export CGO_ENABLED=0

# Charm is intentionally NOT a dependency of the SDK's user/go/go.mod:
# `user/go/ttf` guards that module against broad desktop dependencies. Start
# with a gitignored cache module, then build through a transient modfile beside
# the SDK's own go.mod (Go requires a -modfile to live in that directory).
WORK_DIR="$REPO/.build/pulse-work"
MODFILE="$WORK_DIR/go.mod"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cat >"$MODFILE" <<EOF
module pulse-build

go 1.27

require charm.land/bubbletea/v2 ${BT_VERSION}

require charm.land/lipgloss/v2 ${LG_VERSION}
EOF

# Fetch only declared Go modules into the host module cache. The app build
# remains module-mode so Charm's transitive packages resolve there; no source
# from that cache is committed or vendored into the guest tree.
( cd "$WORK_DIR" && go mod download \
    "charm.land/bubbletea/v2@${BT_VERSION}" \
    "charm.land/lipgloss/v2@${LG_VERSION}" )

BT_MOD_DIR="$(go env GOMODCACHE)/charm.land/bubbletea/v2@${BT_VERSION}"
[ -f "$BT_MOD_DIR/termios_other.go" ] || {
    log "Bubble Tea ${BT_VERSION} missing from module cache at $BT_MOD_DIR"
    exit 1
}

# Go intentionally refuses overlays beneath GOMODCACHE. Stage the module
# into the gitignored build area, then point a temporary module replacement
# at it: this is still a module-cache build, not an in-tree vendor copy.
# bubbletea needs two overlay *replaces* because its originals' build tags
# would otherwise match virelai and supply the wrong implementations.
stage_module() {
    src="$1"
    dest="$2"
    if [ -d "$dest" ]; then
        # Module-cache sources are intentionally read-only. `cp -r` does not
        # preserve that mode the way -a would, but make a prior staged copy
        # removable before refreshing it anyway.
        chmod -R u+w "$dest"
        rm -rf "$dest"
    fi
    mkdir -p "$dest"
    # cp -a would try to preserve the module cache's ownership and fail under
    # set -e when the cache is owned by another user; -r is enough for a
    # gitignored staging directory.
    cp -r "$src/." "$dest/"
    chmod -R u+w "$dest"
}

STAGE="$REPO/.build/pulse-module"
stage_module "$BT_MOD_DIR" "$STAGE"

OVERLAY="$REPO/.build/pulse-overlay.json"
mkdir -p "$(dirname "$OVERLAY")" "$REPO/.build/go"
python3 - "$STAGE" "$REPO" "$OVERLAY" <<'PY'
import json, os, sys

module, repo, out = sys.argv[1:]
replace = {
    # These originals are selected for an unknown GOOS; the overlay changes
    # their build tags and supplies the four Program platform hooks without
    # pretending Virelai has termios or POSIX signals.
    os.path.join(module, "termios_other.go"): os.path.join(repo, "tools/go/overlay/charm/termios_virelai.go"),
    os.path.join(module, "signals_unix.go"): os.path.join(repo, "tools/go/overlay/charm/signals_virelai.go"),
}
with open(out, "w") as f:
    json.dump({"Replace": replace}, f, sort_keys=True)
PY

TEMP_MOD="$REPO/user/go/.pulse.mod"
TEMP_SUM="${TEMP_MOD%.mod}.sum"
cp "$REPO/user/go/go.mod" "$TEMP_MOD"
cat >>"$TEMP_MOD" <<EOF

require charm.land/bubbletea/v2 ${BT_VERSION}

require charm.land/lipgloss/v2 ${LG_VERSION}

replace charm.land/bubbletea/v2 => $STAGE
EOF
trap 'rm -f "$TEMP_MOD" "$TEMP_SUM"' EXIT

OUT="$REPO/.build/go/$NAME"
log "building virelai/pulse with Bubble Tea ${BT_VERSION} + lipgloss/v2 ${LG_VERSION} -> $OUT"
( cd "$REPO/user/go" &&
    GOOS=virelai GOARCH=arm64 go build -mod=mod -modfile "$TEMP_MOD" -overlay "$OVERLAY" \
        -ldflags "-s -w" -o "$OUT" ./pulse )

SIZE="$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
log "wrote $OUT ($SIZE bytes)"
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
    log "FAIL: $SIZE bytes exceeds M72a load_max ($MAX_BYTES)"
    exit 1
fi
log "size ok (<= M72a 32 MiB initialized-image bound; module-cache Charm, no vendor tree)"
