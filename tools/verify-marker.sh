#!/usr/bin/env bash
#
# verify-marker.sh -- ADR 0004 D4 fixed-memory-marker fallback gate
# (docs/status.md gate work item 3, claim 0009).
#
# Gate: after a VZ boot, the kernel persists each takeover stage as the EFI
# non-volatile variable `VirelaiM2` (runtime SetVariable survives
# ExitBootServices on VZ — observed). The runner saves the ordered ladder of
# marker instances to artifacts/marker-dump.txt; this script asserts the
# ladder is present and names the kernel's final stage. This discriminates
# the two VZ serial-gate hypotheses:
#   * ladder ends at M2_SERIA -- the serial probe completed and found no
#     usable MMIO device in the declared windows (layout=none halt).
#   * ladder ends at M2_TABLE -- the identity-map build failed.
#   * ladder ends at M2_READY -- the virtio-pci console was discovered and
#     armed pre-exit (claim 0013, 2026-08-07), then the first banner TX died
#     (post-exit access to the transport hangs on VZ; vm-serial.log 0 B).
#   * a missing later stage (M2_ENTRY / M2_EXIT! / M2_MMUP! / M2_READY)
#     names the window in which the kernel crashed. Historical: before
#     claim 0010 the ladder always ended at M2_MAPD! (identity map built,
#     pre-install) with no M2_MMUP! -- the MMU switch itself was the death
#     site, and the kernel never reached the serial probe.
#
# NOTE on the memory-dump form: the original design scanned this process's
# address space for the BSS marker word on the assumption that the in-process
# VZ guest RAM is host-mapped. That is provably false on VZ (a full
# submap-aware walk finds no guest-RAM region; every M2_* hit is the runner's
# own constant array -- claim 0009). The NVRAM ladder is the working form.
#
# The marker channel is the gate here (it brackets the boot stages even when
# the serial channel's takeover is under test). Run on Apple silicon only
# (VZ VM).
#
# Usage: bash tools/verify-marker.sh
# Evidence saved under artifacts/: m2-marker-gate.txt (this script),
# m2-marker-run.txt (runner output), marker-dump.txt (the ladder dump),
# efi-vars.bin (the variable store), plus the vm-serial.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "=== verify-marker: ADR 0004 D4 fixed-memory-marker fallback gate (NVRAM ladder form) ==="

# --- tool versions (record which Zig/Swift/macOS you ran on) ---------------
zig version; swift --version 2>&1 | head -1; sw_vers

# --- formatting gate ---------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig

# --- build gates ---------------------------------------------------------------
zig build
zig build image

# --- Swift runner build ---------------------------------------------------------
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# Fresh variable store so the ladder in the dump is exactly this run's writes
# (the store is append-per-write and survives across runs otherwise).
rm -f artifacts/efi-vars.bin

# --- THE GATE: boot the VM with the marker dump enabled -----------------------
set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --dump-marker artifacts/marker-dump.txt --timeout 25 \
    --expect "VirelaiOS kernel has seized control." \
    --terminal-marker "kernel terminal state" \
    > artifacts/m2-marker-run.txt 2>&1
RUNNER_RC=$?
set -e
cat artifacts/m2-marker-run.txt

echo
echo "=== marker dump (artifacts/marker-dump.txt) ==="
[ -f artifacts/marker-dump.txt ] || { echo "ERROR: no marker dump produced" >&2; exit 1; }
cat artifacts/marker-dump.txt

# --- loader evidence --------------------------------------------------------------
echo
echo "=== loader trace: /LOADER.TXT on the ESP ==="
LOADER_TXT="$(python3 image/mkfat32.py --cat-file /LOADER.TXT artifacts/disk.img 2>/dev/null || true)"
printf '%s\n' "$LOADER_TXT"

# --- gate assertions ---------------------------------------------------------------
fail=0
[ "$RUNNER_RC" -eq 0 ] || { echo "error: runner exit $RUNNER_RC (marker mode: 0 iff an M2_* marker was found)" >&2; fail=1; }

# The ladder: every "MARKER-GATE: M2_..." line from the runner, in order.
# (plain while-read: mapfile/readarray needs bash 4, and macOS ships bash 3.2)
LADDER=()
while IFS= read -r line; do
    LADDER+=("$line")
done < <(grep '^MARKER-GATE: M2_' artifacts/m2-marker-run.txt || true)
if [ "${#LADDER[@]}" -eq 0 ]; then
    echo "error: no M2_* marker in the ladder (kernel died before its first marker write, or SetVariable failed)" >&2
    fail=1
else
    echo "MARKER-GATE: ladder (${#LADDER[@]} stage(s)):"
    for line in "${LADDER[@]}"; do
        echo "  $line"
    done
    LAST="${LADDER[${#LADDER[@]}-1]#MARKER-GATE: }"
    echo "MARKER-GATE: final stage: $LAST"
fi

if [ "$fail" -ne 0 ]; then
    echo "verify-marker: FAILED (evidence kept under artifacts/)" >&2
    exit 1
fi
echo "verify-marker: PASS — NVRAM ladder captured; final kernel stage: $LAST"
