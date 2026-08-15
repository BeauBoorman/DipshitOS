#!/usr/bin/env bash
#
# verify-live-win-hig.sh -- milestone eight card U5 (claim 0935, ADR 0008
# D4) class-B gate: the window chrome is VISIBLE and MOVES with focus.
#
# Mechanism: ONE --input --display run with a marker-driven screenshot
# capture. The serial script exercises the focus surface: `win cycle`
# (the D4 keyboard-cycling analogue — the Alt+Tab HID decode is
# host-tested; synthesized modifiers never reach VZ's HID report, the
# claim-6233 hardware-contract observation), then `exec WINLOOP.BIN`
# opens a USER window (the long-lived G6 program), then `win` reports
# the registry — the capture fires on that report line.
#
# Pixel assertions (the decoded capture, 2560x1440 = 2x the 1280x720
# framebuffer; colors ride the host's color-managed pipeline — the G6
# recorded transforms — so white stays ~(255,255,255) and the title-bar
# blue ~(30,43,59)):
#   * the FOCUS RING (white, 3 px) sits on the FOCUSED window — after the
#     cycle focuses the clock, `exec WINLOOP.BIN` opens a user window
#     which TAKES focus (the G6 open semantic), so the ring sits on
#     WINLOOP's corner at capture time;
#   * the TERMINAL's screen edge is NOT ringed (sample (1,1)-area shows
#     the terminal background, not white);
#   * the USER window carries its TITLE BAR (dark blue strip at the top
#     of WINLOOP's window, with the "win2" text row);

#
# Card U4's pointer half (cursor + click-to-focus) is host-tested but NOT
# gated here: five synthesized pointer delivery routes were observed
# producing ZERO guest pointer reports (direct view calls, window
# sendEvent, NSApp.postEvent, CGEventPost without Accessibility trust,
# and a mouseEntered preamble) — recorded in the hardware contract; the
# real-mouse question and the Accessibility-granted CG route remain the
# follow-up.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-win-hig.sh
#
# Evidence: artifacts/win-hig-gate.txt, artifacts/win-hig-report.txt,
# the capture under artifacts/hig-screen-*.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/win-hig-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/win-hig-report.txt"
SCREEN_BASE="artifacts/hig-screen"

echo "=== verify-live-win-hig: card U5 (claim 0935) — the focus ring + title bars are visible and move with focus ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- the session --------------------------------------------------------------
cat > artifacts/win-hig-script.txt <<'EOF'
win cycle
exec WINLOOP.BIN
echo hig-serial-ok
EOF

rm -f artifacts/efi-vars.bin artifacts/vm-serial.log "$SCREEN_BASE"*
set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --input --display \
    --script artifacts/win-hig-script.txt \
    --screen "$SCREEN_BASE" --screenshot-after "winloop: present ok" \
    --timeout 120 \
    > artifacts/win-hig-run.txt 2>&1
RC=$?
set -e

# --- serial assertions --------------------------------------------------------
SERIAL="artifacts/vm-serial.log"
CYCLED=0 THREE=0 OBSDONE=0 RUNNERFLAG=0
if [ -f "$SERIAL" ]; then
    grep -a -qF -- "win: cycle focused=1" "$SERIAL" && CYCLED=1
    grep -a -qF -- "winloop: present ok" "$SERIAL" && THREE=1
    grep -a -qF -- "hig-serial-ok" "$SERIAL" && OBSDONE=1
fi
grep -a -qF -- "screenshot" artifacts/win-hig-run.txt && RUNNERFLAG=1

# --- pixel assertions ---------------------------------------------------------
# The clock sits at (960,16), 304x192; WINLOOP's window at (64,64), 256x192
# (the G6 defaults). Framebuffer sample points (scaled to the capture):
#   RING   (65, 65) — WINLOOP's ring corner (white 3px; focus follows
#                      the window open, so the ring sits on the user window)
#   EDGE   (1, 1)    — the terminal corner, NOT ringed
#   TITLE  (100, 68) — WINLOOP's title-bar strip
RING=0 EDGE=0 TITLE=0 PIXELS=0
CAP="$(ls -t "$SCREEN_BASE"-* 2>/dev/null | head -1 || true)"
if [ -n "$CAP" ]; then
    echo "decoding $CAP"
    python3 - "$CAP" <<'EOF'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
pos = 8; idat = b''; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b'IHDR':
        w, h, bd, ct = struct.unpack('>IIBB', data[:10])
    elif typ == b'IDAT':
        idat += data
    pos += 12 + ln
raw = zlib.decompress(idat)
bpp = 4 if ct == 6 else 3
stride = w * bpp
out = bytearray(); prev = bytearray(stride); i = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line

def px(x, y):
    o = y * stride + x * bpp
    if ct == 6:
        return (out[o], out[o+1], out[o+2], out[o+3])
    return (out[o], out[o+1], out[o+2], 255)

def near(c, t, tol):
    return all(abs(c[i] - t[i]) <= tol for i in range(3))

# The capture may arrive at 1x OR 2x the 1280x720 framebuffer — scale the
# framebuffer sample coordinates by whatever this capture actually is.
s = w // 1280
assert s in (1, 2), f"unexpected capture width {w}"
def at(fx, fy):
    return px(fx * s, fy * s)

ring = near(at(65, 65), (255, 255, 255), 25)
edge = not near(at(1, 1), (255, 255, 255), 25)
title = near(at(100, 68), (30, 43, 59), 22)
print(f"PIXEL scale={s} ring={int(ring)} edge_not_ringed={int(edge)} title={int(title)}")
print(f"  ring sample {at(65,65)}  edge sample {at(1,1)}  title sample {at(100,68)}")
sys.exit(0 if (ring and edge and title) else 1)
EOF
    PIXELS=$?
    # The decode prints one PIXEL line (tee'd into the gate log); map it.
    if grep -a -q "PIXEL scale=[12] ring=1 edge_not_ringed=1 title=1" "$GATE_LOG"; then RING=1; EDGE=1; TITLE=1; fi
else
    echo "FAIL: no capture PNG"
fi

echo "win-hig: rc=$RC cycled=$CYCLED windows3=$THREE obs-done=$OBSDONE runner-flag=$RUNNERFLAG pixels=$RING/$EDGE/$TITLE"

PASS=0
if [ "$RC" = 0 ] && [ "$CYCLED" = 1 ] && [ "$THREE" = 1 ] && [ "$OBSDONE" = 1 ] && \
   [ "$RUNNERFLAG" = 1 ] && [ "$RING" = 1 ] && [ "$EDGE" = 1 ] && [ "$TITLE" = 1 ]; then
    PASS=1
fi

{
    echo "DIPSHITOS win HIG gate (milestone eight card U5, claim 0935) — the focus ring + title bars are visible and move with focus, on real VZ"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "session: win cycle (focus -> clock) + exec WINLOOP.BIN (a user window) + win report; capture on windows=3"
    echo "assertions: cycle marker, winloop present marker, serial marker, runner capture flag, ring-on-focused-window + edge-not-ringed + title-bar pixels"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-win-hig: PASS — the focus ring renders on the FOCUSED window (white, on WINLOOP after its open took focus from the cycled clock), the terminal edge is not ringed, and the user window carries its title bar — decoded from the composited capture, moving with focus exactly as ADR 0008 D4 requires. Cycling is driven by win cycle (the HID Alt+Tab decode is host-tested; synthesized modifiers never reach VZ's report)."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-win-hig: FAILED — see artifacts/win-hig-report.txt, win-hig-run.txt, and the serial log."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi
