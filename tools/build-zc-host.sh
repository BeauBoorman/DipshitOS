#!/usr/bin/env bash
#
# build-zc-host.sh -- Z4b (issue #761) host link contract: the target recipe.
#
# Builds a corpus fixture (one or more sources, compiled together — the
# Z3a flat-namespace shape) with HOST zig 0.17 into an ELF64 executable the
# VirelaiOS static loader accepts and runs (verified on VZ: the z05 host
# image exits 72 exactly like the zc-compiled one). This is the "host side"
# of the Z4b dual-run: the SAME source the in-guest compiler compiles, now
# compiled by real zig and linked against the real zc shim
# (user/src/lib/zc.zig), whose asm-svc functions are the actual syscalls.
#
# The recipe (each knob is load-bearing; see docs/archive/line-of-sight.md):
#   * sources are CONCATENATED into one root (flat container) with a
#     `_start` epilogue appended: `export fn _start` calls the fixture's
#     `main`, then parks on zc.exit(0) if main ever returned;
#   * `zig build-exe -target aarch64-freestanding -O ReleaseSmall -fstrip
#     -fno-PIE -fno-entry` — no libc, no synthesized start (the root
#     exports _start), no PIE, no debug info (a trivial image with debug
#     info measures ~283 KiB — over the 256 KiB load cap);
#   * `-T tools/zc-host-link.ld` — the canonical linker script: exactly
#     two PT_LOADs (text+.rodata R+X at 0x0040_0000; data+.bss R+W exactly
#     after), e_entry = _start inside the text file bytes;
#   * `-z max-page-size=4096` — without it lld pads the first segment to a
#     64 KiB file offset and a trivial image is ~65 KiB of slack;
#   * `--dep zc -Mroot=... -Mzc=user/src/lib/zc.zig` — the fixture's
#     @import("zc") resolves to the real shim (the Z0.5 contract);
#   * tools/check-zc-host-contract.py validates the emitted image against
#     elf.zig's parse rules before anything else touches it.
#
# Usage: build-zc-host.sh -o OUT.ELF SRC...        (each SRC a .z/.zig file)
#
# Evidence output (stdout): "CONTRACT OK" from the checker + size summary.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT=""
SRCS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT="$2"; shift 2 ;;
        *) SRCS+=("$1"); shift ;;
    esac
done
[ -n "$OUT" ] || { echo "usage: build-zc-host.sh -o OUT.ELF SRC..." >&2; exit 1; }
[ "${#SRCS[@]}" -ge 1 ] || { echo "build-zc-host: no sources" >&2; exit 1; }
for s in "${SRCS[@]}"; do
    [ -f "$s" ] || { echo "build-zc-host: missing source $s" >&2; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zc-host-build.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Flat root: every source concatenated (same shape the in-guest compiler
# sees), then the _start epilogue. `main` may be `pub fn main` (zig would
# otherwise synthesize its own start — -fno-entry suppresses that) or a
# plain `fn main` (z3a/z3b style).
ROOT_SRC="$TMP/root.zig"
: > "$ROOT_SRC"
for s in "${SRCS[@]}"; do
    cat "$s" >> "$ROOT_SRC"
    printf '\n' >> "$ROOT_SRC"
done
cat >> "$ROOT_SRC" <<'EOF'

export fn _start() callconv(.c) noreturn {
    main();
    zc.exit(0);
}
EOF

zig build-exe -target aarch64-freestanding -O ReleaseSmall -fstrip \
    -fno-PIE -fno-entry -T tools/zc-host-link.ld -z max-page-size=4096 \
    --dep zc -Mroot="$ROOT_SRC" -Mzc=user/src/lib/zc.zig \
    -femit-bin="$OUT"

python3 tools/check-zc-host-contract.py "$OUT"
echo "build-zc-host: $OUT ($(wc -c < "$OUT" | tr -d ' ') B, $(wc -c < "$ROOT_SRC" | tr -d ' ') B root)"
