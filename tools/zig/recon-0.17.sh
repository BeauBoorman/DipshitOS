#!/usr/bin/env bash
# recon-0.17.sh — deterministic Zig-0.17 break reconnaissance for M96a.
#
# Usage: bash tools/zig/recon-0.17.sh [path-to-zig] [report-dir]
#
# Runs the class-A Zig surface under the given compiler and emits a
# canonical, sorted, deduplicated break report plus a sha256 of it. The
# report is intentionally free of timestamps, absolute paths and counts
# that vary with machine state so that two clean runs produce identical
# checksums.
#
# Sections in the report:
#   fmt        — `zig fmt --check` failures over every tracked .zig file
#   build      — `zig build` (default step) compile errors
#   steps      — pass/fail per class-A `zig build` step
#   unittest   — `zig build test` compile errors + test failures
#   zchost     — tools/verify-zc-corpus.sh --host verdict
#   starstar   — files containing `**` (0.17 parse break), sorted
#   bitcast    — every @bitCast site, file:line, sorted
#
# This script changes no product code; it only reads the tree and runs
# the compiler. Build artifacts land in the caller's .zig-cache/zig-out
# as usual; the report itself goes to the report dir.

set -u
cd "$(dirname "$0")/../.."
export LC_ALL=C

ZIG=${1:-zig}
OUT=${2:-artifacts/recon-0.17}
mkdir -p "$OUT"

if ! command -v "$ZIG" >/dev/null 2>&1 && [ ! -x "$ZIG" ]; then
    echo "recon-0.17: zig binary not found: $ZIG" >&2
    exit 2
fi

REPORT="$OUT/report.txt"
: > "$REPORT"

emit() { printf '%s\n' "$@" >> "$REPORT"; }

echo "== zig version ==" >> "$REPORT"
"$ZIG" version >> "$REPORT" 2>&1

# -- fmt ------------------------------------------------------------------
mapfile -t ZIGFILES < <(git ls-files '*.zig' | LC_ALL=C sort)
emit "" "== fmt =="
"$ZIG" fmt --check "${ZIGFILES[@]}" 2>&1 \
    | grep -E 'error:|^[^ ]+\.zig$' \
    | sed 's#^\./##' \
    | LC_ALL=C sort -u >> "$REPORT"
emit "(end fmt)"

# -- build (default) -------------------------------------------------------
emit "" "== build =="
"$ZIG" build 2>&1 \
    | grep -E 'error:|warning:' \
    | LC_ALL=C sort -u >> "$REPORT"
emit "(end build)"

# -- class-A build steps ----------------------------------------------------
emit "" "== steps =="
STEPS=$("$ZIG" build --list-steps 2>/dev/null | tail -n +3 | awk '{print $1}' | LC_ALL=C sort)
SKIP=" run spike-virtio console session marker nvram-console preexit-tx tx-diag zig-guest-check boris-guest boris-check "
for s in $STEPS; do
    case "$SKIP" in
        *" $s "*) continue ;;
    esac
    if "$ZIG" build "$s" >"$OUT/step-last.log" 2>&1; then
        emit "PASS $s"
    else
        emit "FAIL $s"
        grep -E 'error:' "$OUT/step-last.log" | sed 's/^/    /' | LC_ALL=C sort -u >> "$REPORT"
    fi
done
emit "(end steps)"

# -- host unit tests ---------------------------------------------------------
emit "" "== unittest =="
"$ZIG" build test 2>&1 \
    | grep -E 'error:|failed:' \
    | LC_ALL=C sort -u >> "$REPORT"
emit "(end unittest)"

# -- zc host corpus -----------------------------------------------------------
emit "" "== zchost =="
if bash tools/verify-zc-corpus.sh --host >"$OUT/zchost.log" 2>&1; then
    emit "zchost PASS"
else
    emit "zchost FAIL"
    grep -E 'error:|FAIL' "$OUT/zchost.log" | sed 's/^/    /' | LC_ALL=C sort -u >> "$REPORT"
fi
emit "(end zchost)"

# -- `**` sites (0.17 removal) ------------------------------------------------
emit "" "== starstar =="
git grep -l -e '\*\*' -- '*.zig' | LC_ALL=C sort >> "$REPORT"
emit "(end starstar)"

# -- @bitCast sites -----------------------------------------------------------
emit "" "== bitcast =="
git grep -n -e '@bitCast' -- '*.zig' | LC_ALL=C sort -t: -k1,1 -k2,2n >> "$REPORT"
emit "(end bitcast)"

# -- checksum ------------------------------------------------------------------
echo "== sha256 ==" >> "$REPORT"
shasum -a 256 "$REPORT" | awk '{print $1}' > "$OUT/report.sha256"
cat "$OUT/report.sha256" >> "$REPORT"

echo "recon-0.17: report at $REPORT"
echo "recon-0.17: sha256 $(cat "$OUT/report.sha256")"
