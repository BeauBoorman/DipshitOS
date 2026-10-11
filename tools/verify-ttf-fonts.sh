#!/usr/bin/env bash
#
# verify-ttf-fonts.sh -- class A: TrueType font engine verification for
# Inter Regular, Bold, and Italic, and Fira Code (monospace).
#
# Tests:
#   1. TrueType SFNT table parser (head, maxp, hhea, hmtx, loca, glyf, cmap fmt 4 & 12).
#   2. Vector outline decoding and delta coordinate reconstruction.
#   3. Quadratic Bézier subdivision and contour decomposition.
#   4. Scanline coverage anti-aliasing (half-integer subpixel sampling).
#   5. Composite glyph decomposition (accented Latin characters).
#   6. Zero-heap GlyphCache and 32-bpp BGRA alpha blending.
#   7. Proportional string measurement and layout helpers in ui.zig.
#
# Usage:
#   bash tools/verify-ttf-fonts.sh
#
# Evidence saved under artifacts/ttf-fonts-gate.txt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/ttf-fonts-gate.txt"
mkdir -p "$(dirname "$GATE_LOG")"
exec > >(tee "$GATE_LOG") 2>&1

echo "=== verify-ttf-fonts: TrueType Engine & Typography Verification (Inter Regular/Bold/Italic + Fira Code) ==="

# ADR 0028 amendment B byte sizes. A face that is present but the wrong file
# fails here instead of only later, inside the parser.
check_face() {
    local path="$1" want="$2" label="$3" size
    if [ ! -f "$path" ]; then
        echo "FAIL: $label not found at $path" >&2
        exit 1
    fi
    size=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path")
    echo "  $label: $size bytes"
    if [ "$size" != "$want" ]; then
        echo "FAIL: $label is $size bytes, want $want (ADR 0028 amendment B)" >&2
        exit 1
    fi
}

# 1. Assert font files exist
echo
echo "[1/3] Verifying source TrueType font files in image/fonts/"
check_face "image/fonts/Inter-Regular.ttf" 411640 "Inter-Regular.ttf"
check_face "image/fonts/Inter-Bold.ttf" 420428 "Inter-Bold.ttf"
check_face "image/fonts/Inter-Italic.ttf" 417388 "Inter-Italic.ttf"
check_face "image/fonts/FiraCode-Regular.ttf" 289624 "FiraCode-Regular.ttf"

# B7 (M96c): the zig invocations must resolve to the SDK-pinned compiler —
# materialize it via sdk.py and put that dir first, fetching the checksum-
# verified archive when the cache is absent (CI's setup-zig puts the pinned
# zig on PATH but never populates .build/zig-guest; fetch is a verified no-op
# when the archive already exists). A bare /opt/homebrew/bin prepend here let
# an unpinned Homebrew zig win over the pin and broke this gate during M91
# (verify-portable) and M93g (live-web).
python3 tools/zig/sdk.py fetch
ZIG_PIN_DIR="$(python3 tools/zig/sdk.py prepare)"

# 2. Run unit tests for font_ttf.zig
echo
echo "[2/3] Running TrueType parser, rasterizer, composite, cache & blend unit tests"
PATH="/opt/homebrew/opt/gnu-sed/libexec/gnubin:$ZIG_PIN_DIR:$PATH" zig test user/src/lib/font_ttf.zig

# 3. Assert userland compilation with font subsystem
echo
echo "[3/3] Compiling userland with font engine integrated"
# M60 / #1297: EDIT.BIN is gone; M66c (#1485): the Zig notepad is gone too.
# M78c: the last other font-heavy Zig app is retired. DEVCONS.BIN remains the
# compile-time owner of the Zig TrueType/text stack exercised by this gate.
PATH="/opt/homebrew/opt/gnu-sed/libexec/gnubin:$ZIG_PIN_DIR:$PATH" zig build devcons

echo
echo "=== verify-ttf-fonts: PASS (Inter Regular/Bold/Italic & Fira Code verified) ==="
