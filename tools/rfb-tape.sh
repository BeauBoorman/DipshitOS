#!/usr/bin/env bash
#
# rfb-tape.sh -- M84d/M84e class-C demo: a real macOS Screen Sharing viewer
# against the guest seat, through rfbprobe's loopback-only one-viewer bridge
# (ADR 0037 D5(1)) on the hermetic --net stream. Records the guest's own
# scanout as PNGs under gitignored artifacts/. Never gate evidence: the gate
# is live-rfb.spec. Exits 3 with the viewer's transcript when the viewer
# never completes the RFB handshake, instead of producing an empty tape.
# The host bridge's one-shot VNC password crosses a private FIFO, not the
# VMRunner's captured stderr (runner.log); the guest still speaks None.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${RFB_TAPE_OUT:-$ROOT/artifacts/rfb-tape/$(date -u +%Y%m%dT%H%M%SZ)}"
PORT="${RFB_TAPE_PORT:-5901}"
VIEWER=1
TYPE_PASSWORD=0

# Answer Screen Sharing's own password sheet through System Events, so an
# unattended tape can finish the handshake without a human at the keyboard.
# This is RACE-CRITICAL, not cosmetic: the runner has already dialled the
# guest, so the guest's RFB handshake budget (vi.DefaultRecvBudgetNs, 30 s)
# is burning from the moment the bridge starts listening. The password must
# land well inside that. Hence a 0.1 s poll on the one button that proves
# the password sheet is up, and a direct field write rather than
# synthesizing keystrokes. The bridge's one-shot password is alphanumeric
# (bridge_auth.go), so no modifier keys are needed either way.
# Best effort by design: on any failure the operator can still type the
# printed password, and the bridge allows three pre-auth attempts.
# Requires Accessibility for the calling app.
type_password() {
    osascript - "$1" <<'OSA' 2>&1 || true
on run argv
    set pw to item 1 of argv
    tell application "System Events"
        tell process "Screen Sharing"
            repeat 200 times
                try
                    if (exists button "Sign In" of window 1) then
                        set value of text field 1 of window 1 to pw
                        click button "Sign In" of window 1
                        return "typed the one-shot password and clicked Sign In"
                    end if
                end try
                delay 0.1
            end repeat
        end tell
    end tell
    return "no password dialog appeared"
end run
OSA
}

usage() {
    cat <<'EOF'
usage: bash tools/rfb-tape.sh [--dry-run] [--no-viewer] [--type-password]

Boots the seat with --rfb-hermetic, bridges one viewer from 127.0.0.1:$PORT
(RFB_TAPE_PORT, default 5901) into the guest, and opens vnc://127.0.0.1:$PORT
in macOS Screen Sharing. --no-viewer leaves viewer launch to the operator.
--type-password answers Screen Sharing's own password prompt through
System Events instead of waiting for a human (needs Accessibility for the
app that runs this script). Off by default; --no-viewer ignores it.
Enter the printed one-shot password in Screen Sharing, then disconnect
after the desktop appears so the tape can record session teardown.
RFB_TAPE_OUT selects the artifact directory. The bridge serves one
authenticated loopback viewer (up to three pre-auth attempts); the guest
wire remains None.
EOF
}

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --no-viewer) VIEWER=0 ;;
        --type-password) TYPE_PASSWORD=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [ "$DRY_RUN" -eq 1 ]; then
    cat <<EOF
Would build disk, VMRunner (-DSPIKE), rfbprobe, GOTABWM.ELF, and GOCALC.ELF.
Would bridge one viewer on 127.0.0.1:$PORT with a one-shot VNC password and $([ "$VIEWER" -eq 1 ] && echo "open vnc://127.0.0.1:$PORT" || echo "wait for a manual viewer").
Would record $OUT/rfb-{5s,10s,15s,after}.png (after = the first frame served to the viewer).
EOF
    exit 0
fi

[ "$(uname -s)" = Darwin ] || { echo "rfb-tape: requires macOS Virtualization.framework" >&2; exit 1; }
cd "$ROOT"
umask 077
mkdir -p "$OUT/share"
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist \
    host/vm-runner/.build/release/VMRunner
bash tools/go/rfbprobe/build.sh
bash tools/go/build-gotabwm.sh
bash tools/go/build-gocalc.sh

cp -R zig-out/bin/. "$OUT/share/"
cp .build/go/GOTABWM.ELF .build/go/GOCALC.ELF "$OUT/share/"
cp image/apps.txt "$OUT/share/APPS.TXT"
cp image/WALLPAPER.QOI "$OUT/share/"
cp image/fonts/Inter-Regular.ttf "$OUT/share/INTER.TTF"
cp image/fonts/Inter-Bold.ttf "$OUT/share/INTERB.TTF"
cp image/fonts/Inter-Italic.ttf "$OUT/share/INTERI.TTF"
cp image/fonts/Inter-BoldItalic.ttf "$OUT/share/INTERBI.TTF"
cp image/fonts/FiraCode-Regular.ttf "$OUT/share/FIRACODE.TTF"
# M99l (#2189): the chrome face is the cascade's symbol tail, and FONTS.TXT is
# the manifest that wires it — the Go registry only.
cp image/fonts/VirelaiChrome-Regular.ttf "$OUT/share/CHROME.TTF"
cp image/fonts/fonts.txt "$OUT/share/FONTS.TXT"
# M99m (#2190): the serif role primary and the CJK cascade tail.
cp image/fonts/NotoSerif-Regular.ttf "$OUT/share/NOTOSERF.TTF"
cp image/fonts/NotoSansJP-Regular.ttf "$OUT/share/NOTOCJK.TTF"
printf '#v2\nwm=none\n' >"$OUT/share/SETTINGS.TXT"
cat >"$OUT/boot.txt" <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
set GOMAXPROCS=1
exec GOTABWM.ELF --rfb-hermetic
EOF
cat >"$OUT/calc.txt" <<'EOF'
dui focus 0
exec GOCALC.ELF
EOF

# A full-screen hextile update took nearly five minutes on the measured
# stop-and-wait guest TCP seam. Leave room for human password entry and
# the viewer's clean disconnect; this is a class-C tape, not a gate.
mkfifo -m 600 "$OUT/password.pipe"
host/vm-runner/.build/release/VMRunner \
    --overlay-base artifacts/disk.img --vars "$OUT/vars.bin" \
    --cvc-file "$OUT/share" --serial "$OUT/serial.log" \
    --screen "$OUT/rfb.png" --screenshot-after 'gotabwm: rfb frame' \
    --net "$OUT/cap.bin" --net-arp-respond 10.0.0.2 \
    --net-tcp-connect 10.0.0.1:5900 \
    --net-tcp-connect-stream .build/go/rfbprobe \
    --net-tcp-connect-stream-arg "-bridge=127.0.0.1:$PORT" \
    --net-tcp-connect-stream-arg "-bridge-password-fifo=$OUT/password.pipe" \
    --net-tcp-connect-after 'gocalc: present' \
    --script "$OUT/boot.txt" \
    --script2 "$OUT/calc.txt" --script2-after 'gotabwm: win focus' \
    --script-expect 'gotabwm: rfb done' --script-expect-tail 4 --timeout 600 \
    >"$OUT/runner.log" 2>&1 &
RUNNER=$!

for _ in $(seq 1 300); do
    grep -q 'RFBPROBE: bridge listening' "$OUT/runner.log" 2>/dev/null && break
    kill -0 "$RUNNER" 2>/dev/null || break
    sleep 0.5
done
if grep -q 'RFBPROBE: bridge listening' "$OUT/runner.log"; then
    password="$(cat "$OUT/password.pipe")"
    rm "$OUT/password.pipe"
    echo "rfb-tape: Screen Sharing one-shot VNC password: $password"
    if [ "$VIEWER" -eq 1 ]; then
        # A previous Screen Sharing process can keep a stale connection
        # dialog and ignore a second URL open. Give each tape a fresh app.
        if [ "$TYPE_PASSWORD" -eq 1 ]; then
            # System Events addresses a process by name, so a leftover
            # instance would win the race for the prompt. This tape owns
            # the viewer's lifetime, so clear any stale one first.
            pkill -x "Screen Sharing" 2>/dev/null || true
        fi
        open -n -a "Screen Sharing" "vnc://127.0.0.1:$PORT"
        if [ "$TYPE_PASSWORD" -eq 1 ]; then
            echo "rfb-tape: --type-password: $(type_password "$password")"
        fi
    else
        echo "rfb-tape: connect a viewer to vnc://127.0.0.1:$PORT within 120 s"
    fi
    unset password
fi
rc=0
wait "$RUNNER" || rc=$?

grep -a 'RFBPROBE: bridge' "$OUT/runner.log" || true
grep -a 'gotabwm: rfb' "$OUT/serial.log" || true
if ! grep -aq 'gotabwm: rfb frame' "$OUT/serial.log"; then
    echo "rfb-tape: BLOCKED: the viewer was never served a frame (runner rc=$rc); transcript above, logs in $OUT" >&2
    exit 3
fi
if [ "$rc" -ne 0 ]; then
    echo "rfb-tape: runner failed (rc=$rc); logs in $OUT" >&2
    exit "$rc"
fi
python3 - "$OUT" <<'PY'
import os, struct, sys
out = sys.argv[1]
for name in ("rfb-after.png",):
    p = os.path.join(out, name)
    b = open(p, "rb").read()
    if b[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("not a real scanout PNG: " + p)
    w, h = struct.unpack(">II", b[16:24])
    print("scanout", name, w, h, len(b), "bytes")
PY
if command -v magick >/dev/null 2>&1; then
    magick -delay 100 -loop 0 "$OUT"/rfb-{5s,10s,15s,after}.png "$OUT/rfb.gif" 2>/dev/null || true
fi
echo "rfb-tape: $OUT (demonstration, not gate evidence)"
