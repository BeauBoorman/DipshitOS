#!/usr/bin/env bash
#
# session.sh -- boot an INTERACTIVE, WINDOWED VirelaiOS desktop.
#
# This is the human front door the gate fleet never needed: the class-B/C
# gates boot a VM, drive it with scripts, assert serial evidence, and exit.
# A person who just wants to *use* the machine had to reconstruct the gate
# harness by hand. This script packages the missing pieces:
#
#   1. build the guest + image + the SPIKE runner (the host file channel
#      `--cvc-file` implies the custom-virtio device shape, which only the
#      SPIKE build declares);
#   2. seed a PERSISTENT host share (apps, APPS.TXT, wallpaper, fonts, and
#      the Go seat) -- M34/HF6 removed the apps from the disk image, so
#      without this the shell has nothing to `exec`;
#   3. boot with the GPU window + USB keyboard/pointing devices attached
#      (`--display --input`);
#   4. let the compiled boot default apply: M59 (issue #1298) flipped `wm`
#      to the GO seat, so a boot lands in GOTABWM.ELF. The `.virelairc` in
#      the share says so and offers the two escapes -- `settings set wm
#      tabwm` for the Zig desktop, VIRELAI_SESSION_NO_TABWM=1
#      for the classic floating-window WM. When the Go seat or its starter
#      shell cannot be built, the rc falls back to `tabwm start` and says so.
#
# The canonical `artifacts/disk.img` is attached READ-ONLY through a
# throwaway ASIF overlay, so a session never mutates the shared gate image.
# User files, settings, history, and the wallpaper live in the share and
# persist between sessions.
#
# Apple silicon + macOS 27+ only (Virtualization.framework + DiskImageKit).
# This is NOT a gate and is not run in CI.
#
# Usage:
#   bash tools/session.sh            # windowed desktop
#   just session
#
# Environment:
#   VIRELAI_SESSION_SHARE=<dir>      share directory (default artifacts/session-share)
#   VIRELAI_SESSION_NO_TABWM=1       no seat autostart: the floating-window WM
#   VIRELAI_SESSION_NO_GOTABWM=1     do not build/stage the Go seat and shell
#                                    (the rc then falls back to `tabwm start`)
#   VIRELAI_SESSION_SKIP_BUILD=1     skip the build step (reuse the last build)
#
# Controls: close the VM window, choose Quit VirelaiOS (Cmd-Q), or press
# Ctrl-C in this terminal to stop the VM. Rerun the command to relaunch.
# Guest serial output is written to
# artifacts/session-serial.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SHARE="${VIRELAI_SESSION_SHARE:-$ROOT/artifacts/session-share}"
SERIAL_LOG="$ROOT/artifacts/session-serial.log"
RUNNER="host/vm-runner/.build/release/VMRunner"

# --- 1. build ---------------------------------------------------------------
if [ "${VIRELAI_SESSION_SKIP_BUILD:-0}" != "1" ]; then
    echo "session: building guest + image (zig build, zig build image)"
    zig build
    zig build image
    echo "session: building the SPIKE VMRunner (host file channel needs the custom-virtio shape)"
    swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
    codesign --force --sign - --entitlements host/vm-runner/entitlements.plist "$RUNNER"
fi

[ -x "$RUNNER" ] || { echo "session: ERROR — $RUNNER is missing; run 'just session' without VIRELAI_SESSION_SKIP_BUILD=1 (or build it with 'swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE')"; exit 1; }
[ -f "$ROOT/artifacts/disk.img" ] || { echo "session: ERROR — artifacts/disk.img is missing; create it with 'zig build image'"; exit 1; }

# --- 2. seed the persistent share (idempotent; never clobbers user files) ---
mkdir -p "$SHARE"

# Refresh executable assets only. The bundle is not a document/settings
# backup and must never recursively overwrite the persistent share.
if [ -d "$ROOT/zig-out/bin" ]; then
    for src in "$ROOT"/zig-out/bin/*.BIN "$ROOT"/zig-out/bin/*.ELF "$ROOT"/zig-out/bin/*.SO; do
        [ -f "$src" ] || continue
        cp "$src" "$SHARE/"
    done
fi
# Freshly generated ELF fixtures (static + the M30/M31 dynamic set) so the
# dynamic apps resolve even when the last image build predates them.
if [ -f "$ROOT/tools/mkhello-elf.py" ]; then
    python3 "$ROOT/tools/mkhello-elf.py" "$SHARE/HELLO.ELF" 2>/dev/null || true
    python3 "$ROOT/tools/mkhello-elf.py" --crash "$SHARE/CRASH.ELF" 2>/dev/null || true
fi
if [ -f "$ROOT/tools/mkdyn-elf.py" ]; then
    python3 "$ROOT/tools/mkdyn-elf.py" "$SHARE" 2>/dev/null || true
fi
# Desktop manifest + wallpaper (the guest reads /host/APPS.TXT and /host/WALLPAPER.QOI).
[ -f "$ROOT/image/apps.txt" ] && cp "$ROOT/image/apps.txt" "$SHARE/APPS.TXT"
[ -f "$ROOT/image/WALLPAPER.QOI" ] && cp "$ROOT/image/WALLPAPER.QOI" "$SHARE/WALLPAPER.QOI"
# Launcher emblem (#2054): the mascot QOI fixture, read at /host/SEXIBURGER.QOI.
[ -f "$ROOT/user/src/lib/fixtures/qoi/mascot_64x64.qoi" ] && cp "$ROOT/user/src/lib/fixtures/qoi/mascot_64x64.qoi" "$SHARE/SEXIBURGER.QOI"
# TrueType fonts (Inter Regular/Bold/Italic for UI, Fira Code for the terminal).
# Share names frozen by M69d #1531 D1.
[ -f "$ROOT/image/fonts/Inter-Regular.ttf" ] && cp "$ROOT/image/fonts/Inter-Regular.ttf" "$SHARE/INTER.TTF"
[ -f "$ROOT/image/fonts/Inter-Bold.ttf" ] && cp "$ROOT/image/fonts/Inter-Bold.ttf" "$SHARE/INTERB.TTF"
[ -f "$ROOT/image/fonts/Inter-Italic.ttf" ] && cp "$ROOT/image/fonts/Inter-Italic.ttf" "$SHARE/INTERI.TTF"
[ -f "$ROOT/image/fonts/FiraCode-Regular.ttf" ] && cp "$ROOT/image/fonts/FiraCode-Regular.ttf" "$SHARE/FIRACODE.TTF"
# M86d: the appkit dialog's tinted chrome glyphs share this companion face.
[ -f "$ROOT/image/fonts/VirelaiChrome-Regular.ttf" ] && cp "$ROOT/image/fonts/VirelaiChrome-Regular.ttf" "$SHARE/CHROME.TTF"
# M99l (#2189): the font registry manifest. Go consumers read /host/FONTS.TXT;
# the frozen Zig engine ignores it (ADR 0034).
[ -f "$ROOT/image/fonts/fonts.txt" ] && cp "$ROOT/image/fonts/fonts.txt" "$SHARE/FONTS.TXT"

# The GO seat (M59, issue #1298): the compiled `wm` default is `gotabwm`, so
# a default boot looks for GOTABWM.ELF ON THE SHARE. Build it with the
# GOOS=virelai fork toolchain and stage it; if that is unavailable the
# session still opens, with an honest warning and the Zig TABWM fallback (the
# rc below says which). The default first-boot workspace also needs GOSH.ELF.
GO_SEAT_STAGED=0
if [ "${VIRELAI_SESSION_NO_GOTABWM:-0}" != "1" ]; then
    # NAME is the existing manifest executable field, not a new schema. The
    # seat and first-boot shell are the only non-catalog prerequisites.
    go_apps="$(python3 - "$ROOT/image/apps.txt" <<'PY'
import pathlib, sys
names = ["GOTABWM.ELF", "GOSH.ELF"]
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "|" not in line:
        continue
    name = line.split("|", 1)[0].strip()
    if name.endswith(".ELF") and name not in names:
        names.append(name)
print("\n".join(names))
PY
)"
    while IFS= read -r app; do
        case "$app" in
            GOFILES.ELF) builder=files ;;
            GOHELP.ELF) builder=help ;;
            *) builder="$(printf '%s' "${app%.ELF}" | tr '[:upper:]' '[:lower:]')" ;;
        esac
        script="$ROOT/tools/go/build-$builder.sh"
        if [ ! -f "$script" ]; then
            echo "session: WARNING — $app unavailable: missing builder $script"
        elif ! bash "$script"; then
            echo "session: WARNING — $app unavailable: builder failed ($script)"
        elif [ ! -s "$ROOT/.build/go/$app" ]; then
            echo "session: WARNING — $app unavailable: builder produced no binary"
        else
            cp "$ROOT/.build/go/$app" "$SHARE/$app"
            echo "session: staged $app"
        fi
        # A failed builder never copies a stale output or reports success.
        # A binary already on a persistent share remains user-owned; exec
        # still validates that image and reports a real load failure.
    done <<< "$go_apps"
    if [ -s "$SHARE/GOTABWM.ELF" ] && [ -s "$SHARE/GOSH.ELF" ]; then
        GO_SEAT_STAGED=1
    else
        echo "session: WARNING — the Go seat or its GOSH.ELF first-boot shell is unavailable."
        echo "session:           build commands: 'bash tools/go/build-gotabwm.sh' and 'bash tools/go/build-gosh.sh'."
        echo "session:           if the fork toolchain is missing, provision it with 'bash tools/go/apply.sh && just go-toolchain'."
        echo "session:           the Zig TABWM seat is the fallback when this share has no .virelairc."
    fi
fi

# --- 3. the session startup file (only written when absent) -----------------
RC_FILE="$SHARE/.virelairc"
if [ ! -f "$RC_FILE" ]; then
    if [ "${VIRELAI_SESSION_NO_TABWM:-0}" = "1" ]; then
        # No seat at all: the classic floating-window WND desktop.
        printf '%s\n' \
            '# VirelaiOS session startup — edit freely. Each line runs at boot.' \
            '# "wnd start" boots the classic floating-window WM and suppresses the' \
            '# boot-default seat. Remove the line to get the Go seat instead.' \
            'wnd start' > "$RC_FILE"
    elif [ "$GO_SEAT_STAGED" = "1" ]; then
        # M59 (issue #1298): the compiled default is the GO seat, so this file
        # deliberately starts NO manager — the boot default decides. Naming a
        # seat here would override it (the rc runs before the idle autostart).
        printf '%s\n' \
            '# VirelaiOS session startup — edit freely. Each line runs at boot.' \
            '# No WM line here on purpose: the boot default seats the GO desktop' \
            '# (GOTABWM.ELF, `settings set wm gotabwm`).' \
            '#   older tabbed Zig desktop:  settings set wm tabwm' \
            '#   classic floating windows:  settings set wm none  +  wnd start' \
            '#   back to the Go seat:       settings set wm gotabwm' > "$RC_FILE"
    else
        # No Go seat on this machine: keep the pre-M59 behaviour rather than
        # autostarting a seat that is not there.
        printf '%s\n' \
            '# VirelaiOS session startup — edit freely. Each line runs at boot.' \
            '# GOTABWM.ELF could not be built, so this session boots the Zig' \
            '# TABWM seat: uncomment/keep the next line.' \
            'tabwm start' > "$RC_FILE"
    fi
fi

# --- 3b. the real clock seed ------------------------------------------------
# The guest has no RTC and the kernel has no time-of-day source, so record
# the host's LOCAL time-of-day as seconds since midnight. TABWM reads
# /host/.clock and advances it with its 1 Hz session tick (falling back to
# honest uptime when the file is absent). Rewritten every session so it is
# current at boot.
clock_secs=$(( 10#$(date +%H) * 3600 + 10#$(date +%M) * 60 + 10#$(date +%S) ))
printf '%s\n' "$clock_secs" > "$SHARE/.clock"

# --- 4. boot ----------------------------------------------------------------
# Per-run throwaway EFI variable store; the disk image stays pristine via
# --overlay-base (a fresh ASIF overlay is discarded at runner exit).
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-session.XXXXXX")"
cleanup() { rm -rf "$RUN_DIR"; }
trap cleanup EXIT

# Package only this invocation's runner, not the share. Launch its executable
# directly so the terminal owns/waits for the VM process (not `open`'s helper).
# The raw VMRunner remains the CLI gate entrypoint.
SESSION_APP="$RUN_DIR/VirelaiOS.app"
mkdir -p "$SESSION_APP/Contents/MacOS"
cp "$ROOT/host/vm-runner/Resources/Session-Info.plist" "$SESSION_APP/Contents/Info.plist"
cp "$RUNNER" "$SESSION_APP/Contents/MacOS/VirelaiOS"
codesign --force --sign - --entitlements "$ROOT/host/vm-runner/entitlements.plist" "$SESSION_APP"

RUNNER_PID=""
end_session() {
    local sig="$1" code="$2"
    trap '' INT TERM HUP
    if [ -n "$RUNNER_PID" ]; then
        kill -"$sig" "$RUNNER_PID" 2>/dev/null || true
        # Never remove the bundle/vars while the child still owns a VM.
        wait "$RUNNER_PID" || true
    fi
    exit "$code"
}
trap 'end_session INT 130' INT
trap 'end_session TERM 143' TERM
trap 'end_session HUP 129' HUP

# The Go seat's startup probe waits for a focus-loss event after opening its
# own window. In an automated gate the harness focuses the monitor window;
# provide the same one-shot handoff here so a fresh desktop reaches its shell
# workspace without requiring a startup click.
printf '%s\n' 'dui focus 0' > "$RUN_DIR/session-start.txt"

cat <<EOF

>>>>>>>>>> VirelaiOS session <<<<<<<<<<

A 1280x720 VM window is opening. The default Go seat (GOTABWM.ELF) starts a
first-boot GOSH shell workspace when there is no saved session. The Zig TABWM
seat remains available with \`settings set wm tabwm\`.

  * the seat's markers and the guest shell output are in
      artifacts/session-serial.log

The guest serial log is written to artifacts/session-serial.log.
Your files persist in: $SHARE
Close the VM window, choose Quit VirelaiOS (Cmd-Q), or press Ctrl-C here
to stop the VM. Rerun this command to relaunch; VM RAM is not persisted.

EOF

# A GUI parent's bundle identity belongs to that app, not this CLI runner.
# Do not let macOS associate the independent VM window with Factory/Terminal.
env -u __CFBundleIdentifier "$SESSION_APP/Contents/MacOS/VirelaiOS" \
    --overlay-base "$ROOT/artifacts/disk.img" --vars "$RUN_DIR/efi-vars.bin" \
    --serial "$SERIAL_LOG" \
    --cvc-file "$SHARE" \
    --script "$RUN_DIR/session-start.txt" --script-after 'gotabwm: win focus' \
    --display --input --host-session \
    --timeout 0 &
RUNNER_PID=$!
echo "session: owned VM pid=$RUNNER_PID app=$SESSION_APP"
if wait "$RUNNER_PID"; then
    exit 0
else
    code=$?
    echo "session: VM runner exited with status $code; see the terminal diagnostics and $SERIAL_LOG" >&2
    exit "$code"
fi
