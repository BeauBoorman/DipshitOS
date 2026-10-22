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
#      SPIKE build declares) and the GO apps -- M122a (issue #2570): the
#      app loop is INCREMENTAL, driven by tools/go/ensure-guest-elf.sh's
#      source+ELF hash stamps, so a warm `just session` rebuilds only what
#      changed instead of re-running ~19 unconditional builders. A
#      toolchain doctor runs before any build and names the one command
#      that fixes a missing piece (zig, swift, the GOOS=virelai fork)
#      rather than letting it die deep in a build log or silently booting
#      the Zig-seat fallback;
#   2. seed a PERSISTENT host share (apps, APPS.TXT, wallpaper, fonts, and
#      the Go seat) -- M34/HF6 removed the apps from the disk image, so
#      without this the shell has nothing to `exec`;
#   3. boot with the GPU window + USB keyboard/pointing devices attached
#      (`--display --input`);
#   4. arm the host-integration lanes by DEFAULT (M114c #2456, M127d #2602):
#      provision the `host-int` credential in the share's SECRETS.TXT
#      (app-bound to GOTABWM.ELF, which OWNERS.TXT names uid_system-owned)
#      and boot with `--host-clipboard --host-drop --host-notify
#      --host-outbox --sound --net-nat`. `--no-host-int` disarms the four
#      lanes (and skips the credential); `--no-sound`/`--no-net-nat` switch
#      their own feature;
#   5. let the compiled boot default apply: M59 (issue #1298) flipped `wm`
#      to the GO seat, so a boot lands in GOTABWM.ELF. The `.virelairc` in
#      the share says so and offers the two escapes -- `settings set wm
#      tabwm` for the Zig desktop, VIRELAI_SESSION_NO_TABWM=1
#      for the classic floating-window WM. When the Go seat or its starter
#      shell cannot be built, the rc falls back to `tabwm start` and says so.
#
# M115c (issue #2462): the session is a PERSISTENT machine. Everything that
# used to be thrown away per run lives in a `.virelaivm` profile bundle
# (default artifacts/session.virelaivm): the EFI variable store, the ASIF
# overlay over the read-only gate image (boot-disk writes now survive a
# relaunch), the vlfs.img data disk, the share/ directory, the machine
# identifier, and the saved-state/ dir reserved for M115d. The bundle's
# manifest also pins a stable identity the packaged session app stamps as
# its CFBundleIdentifier at a stable path, so macOS TCC sees ONE
# responsible process across sessions and sound/notify grants stick.
# User files, settings, history, and the wallpaper live in the profile's
# share/ and persist between sessions.
#
# Apple silicon + macOS 27+ only (Virtualization.framework + DiskImageKit).
# This is NOT a gate and is not run in CI.
#
# Usage:
#   bash tools/session.sh            # windowed desktop + host lanes armed
#   bash tools/session.sh --no-host-int   # windowed desktop, lanes off
#   just session
#
# Flags:
#   --no-host-int    do NOT arm --host-clipboard/--host-drop/--host-notify/
#                    --host-outbox (and skip the host-int credential
#                    provisioning)
#   --no-sound       do not attach the audio device
#   --no-net-nat     do not attach the NAT network device
#   --save-capable   ride the share on Apple's virtio-fs instead of
#                    --cvc-file so VZ save/restore does not refuse the
#                    device set (M120a): suspend/snapshot are ARMED, but
#                    the cvc-only host lanes (clipboard/drop/notify/outbox)
#                    and the app-bound credentials (host-int, os-update,
#                    agent-hmac) cannot be served on this posture.
#   --resume         boot the profile's saved-state/ (the continuation of
#                    a ctl suspend); implies --save-capable
#   --provision-only mint + seed + provision, then exit before packaging
#                    or launching (the class-B gate drives its own boots)
#   --dry-run        report what a run would do — the toolchain doctor plus
#                    each Go app's fresh/stale/missing/nobuilder plan row —
#                    then exit before any build, staging, or boot
#
# M120a (issue #2558): the session always boots with --vsock --vsock-ctl
# and always carries the vsock-ctl credential, so the PWR menu's Suspend
# gets an honest verdict instead of `no_device`. The share transport is
# the M115g split made a flag: cvc-file for the app-bound lanes (the
# default), virtio-fs when save/restore must not be refused.
#
# Environment:
#   VIRELAI_SESSION_PROFILE=<path>   .virelaivm bundle (default artifacts/session.virelaivm)
#   VIRELAI_SESSION_SHARE=<dir>      share directory (default <profile>/share)
#   VIRELAI_SESSION_NO_TABWM=1       no seat autostart: the floating-window WM
#   VIRELAI_SESSION_NO_GOTABWM=1     do not build/stage the Go seat and shell
#                                    (the rc then falls back to `tabwm start`)
#   VIRELAI_SESSION_SKIP_BUILD=1     skip EVERY build step — zig, swift, and
#                                    the Go app builders — reusing the last
#                                    .build/go output (staged files, the
#                                    runner, and artifacts/disk.img must
#                                    already exist)
#
# Controls: close the VM window, choose Quit VirelaiOS (Cmd-Q), or press
# Ctrl-C in this terminal to stop the VM. Rerun the command to relaunch.
# Guest serial output is written to
# artifacts/session-serial.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOST_INT=1
SOUND=1
NET_NAT=1
SAVE_CAPABLE=0
RESUME=0
PROVISION_ONLY=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --no-host-int)    HOST_INT=0 ;;
        --no-sound)       SOUND=0 ;;
        --no-net-nat)     NET_NAT=0 ;;
        --save-capable)   SAVE_CAPABLE=1 ;;
        --resume)         RESUME=1; SAVE_CAPABLE=1 ;;
        --provision-only) PROVISION_ONLY=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        *) echo "session: unknown argument '$arg' (supported: --no-host-int --no-sound --no-net-nat --save-capable --resume --provision-only --dry-run)" >&2; exit 2 ;;
    esac
done

PROFILE="${VIRELAI_SESSION_PROFILE:-$ROOT/artifacts/session.virelaivm}"
SHARE="${VIRELAI_SESSION_SHARE:-$PROFILE/share}"
SERIAL_LOG="$ROOT/artifacts/session-serial.log"
RUNNER="host/vm-runner/.build/release/VMRunner"
ENSURE="$ROOT/tools/go/ensure-guest-elf.sh"
SKIP_BUILD=0
if [ "${VIRELAI_SESSION_SKIP_BUILD:-0}" = "1" ]; then SKIP_BUILD=1; fi

# --- 0. the Go app rebuild plan + toolchain doctor (M122a #2570) -------------
# NAME is the existing manifest executable field, not a new schema. The seat
# and first-boot shell are the only non-catalog prerequisites; the M120a
# persistence tools (GOUPD/AGENTD — the credentials below bind to them) are
# not manifest apps and stage even under VIRELAI_SESSION_NO_GOTABWM=1, which
# disables the SEAT, not the machine's own wiring.
session_go_apps() {
    python3 - "$ROOT/image/apps.txt" "${VIRELAI_SESSION_NO_GOTABWM:-0}" <<'PY'
import pathlib, sys
names = []
if sys.argv[2] != "1":
    names = ["GOTABWM.ELF", "GOSH.ELF"]
    for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "|" not in line:
            continue
        name = line.split("|", 1)[0].strip()
        if name.endswith(".ELF") and name not in names:
            names.append(name)
for tool in ("GOUPD.ELF", "AGENTD.ELF"):
    if tool not in names:
        names.append(tool)
# M122c (#2572): catalog rows open a window, so the pure-CLI tools left
# the manifest — but they stay staged, because `exec GOSNAP.ELF ls` /
# `exec GODIFF.ELF a b` in a shell are how they are honestly driven.
for tool in ("GOSNAP.ELF", "GODIFF.ELF"):
    if tool not in names:
        names.append(tool)
print("\n".join(names))
PY
}

go_app_builder() {  # NAME.ELF -> tools/go/build-*.sh (session-side mirror of ensure's builder_rel)
    case "$1" in
        GOFILES.ELF) echo "tools/go/build-files.sh" ;;
        GOHELP.ELF)  echo "tools/go/build-help.sh" ;;
        *) echo "tools/go/build-$(printf '%s\n' "${1%.ELF}" | tr '[:upper:]' '[:lower:]').sh" ;;
    esac
}

GO_APPS="$(session_go_apps)"
# One ensure-guest-elf pass: "APP fresh|stale|missing|nobuilder builder" per
# line. A missing ensure-guest-elf degenerates to build-everything, the
# pre-M122a behaviour.
if [ -f "$ENSURE" ]; then
    APP_PLAN="$(bash "$ENSURE" plan $GO_APPS)"
else
    APP_PLAN=""
    echo "session: WARNING — $ENSURE is missing; freshness checks are off (every app rebuilds)" >&2
fi
app_status() {  # NAME.ELF -> fresh|stale|missing|nobuilder|unknown (plan rows key on the base name)
    printf '%s\n' "$APP_PLAN" | awk -v app="${1%.ELF}" '$1 == app { print $2; found=1; exit } END { if (!found) print "unknown" }'
}

doctor_fail=0
if [ "$SKIP_BUILD" = "1" ]; then
    echo "session: doctor: skipped — VIRELAI_SESSION_SKIP_BUILD=1 reuses the last build"
else
    if command -v zig >/dev/null 2>&1; then
        echo "session: doctor: zig ok"
    else
        echo "session: doctor: zig MISSING — the guest build needs it (fix: brew install zig)"
        doctor_fail=1
    fi
    if command -v swift >/dev/null 2>&1; then
        echo "session: doctor: swift ok"
    else
        echo "session: doctor: swift MISSING — the SPIKE VMRunner needs it (fix: install the Xcode Command Line Tools: xcode-select --install)"
        doctor_fail=1
    fi
    # The GOOS=virelai fork matters only when a staged app must (re)build —
    # a warm cache needs no Go toolchain at all. That is the point of the
    # incremental build: do not demand a toolchain the run will not invoke.
    need_build=0
    for app in $GO_APPS; do
        case "$(app_status "$app")" in
            stale|missing|unknown) need_build=$((need_build + 1)) ;;
        esac
    done
    FORK_DIR="${GO_FORK_DIR:-$(dirname "$ROOT")/go-virelai}"
    if [ "$need_build" -eq 0 ]; then
        echo "session: doctor: go-fork not needed — every staged app is fresh"
    elif grep -q '"virelai"' "$FORK_DIR/src/internal/syslist/syslist.go" 2>/dev/null; then
        if [ -x "$FORK_DIR/bin/go" ]; then
            echo "session: doctor: go-fork ok ($FORK_DIR)"
        else
            echo "session: doctor: go-fork PATCHED BUT UNBUILT — $FORK_DIR/bin/go is missing and $need_build app(s) need a build"
            echo "session: doctor:   fix: just go-toolchain"
            doctor_fail=1
        fi
    else
        echo "session: doctor: go-fork MISSING/UNPATCHED at $FORK_DIR — $need_build app(s) need a build"
        echo "session: doctor:   fix: bash tools/go/apply.sh && just go-toolchain"
        doctor_fail=1
    fi
    # mkfs.vlfs is the host-built data-disk formatter (M120a); it needs the
    # stock host `go`, not the fork. Missing stays a warning — the session
    # still boots, /disk just will not mount this run.
    if [ -x "$ROOT/.build/go/mkfs.vlfs" ]; then
        echo "session: doctor: mkfs.vlfs ok"
    elif command -v go >/dev/null 2>&1; then
        echo "session: doctor: mkfs.vlfs builds on demand via tools/go/vlfs/build.sh (host go ok)"
    else
        echo "session: doctor: mkfs.vlfs MISSING and no host go to build it (fix: brew install go) — vlfs.img stays unformatted"
    fi
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "session: --dry-run — nothing is built, staged, provisioned, or booted"
    if [ "$SKIP_BUILD" = "1" ]; then
        echo "session:   build step: skipped (VIRELAI_SESSION_SKIP_BUILD=1)"
    else
        echo "session:   build step: zig build; zig build image; swift build (SPIKE VMRunner) would run"
    fi
    echo "session:   Go apps (ensure-guest-elf plan):"
    plan_fresh=0; plan_rebuild=0; plan_nobuilder=0
    for app in $GO_APPS; do
        status="$(app_status "$app")"
        case "$status" in
            fresh)
                if [ "$SKIP_BUILD" != "1" ] && { [ ! -f "$SHARE/$app" ] || ! cmp -s "$ROOT/.build/go/$app" "$SHARE/$app"; }; then
                    printf 'session:     %-14s fresh — up-to-date build, would restage into the share\n' "$app"
                else
                    printf 'session:     %-14s fresh — skip\n' "$app"
                fi
                plan_fresh=$((plan_fresh + 1)) ;;
            nobuilder)
                printf 'session:     %-14s no builder (%s) — stays unavailable\n' "$app" "$(go_app_builder "$app")"
                plan_nobuilder=$((plan_nobuilder + 1)) ;;
            *)
                if [ "$SKIP_BUILD" = "1" ]; then
                    printf 'session:     %-14s %s — build skipped (VIRELAI_SESSION_SKIP_BUILD=1)\n' "$app" "$status"
                else
                    printf 'session:     %-14s %s — would rebuild via %s\n' "$app" "$status" "$(go_app_builder "$app")"
                fi
                plan_rebuild=$((plan_rebuild + 1)) ;;
        esac
    done
    printf 'session:   plan: %d fresh, %d would rebuild, %d without a builder\n' "$plan_fresh" "$plan_rebuild" "$plan_nobuilder"
    exit 0
fi

if [ "$doctor_fail" = "1" ]; then
    echo "session: ERROR — the toolchain doctor found a MISSING piece (above). Fix it and rerun; nothing was built or booted." >&2
    echo "session:   to reuse the previous build's output instead: VIRELAI_SESSION_SKIP_BUILD=1 just session" >&2
    exit 1
fi

# --- 1. build ---------------------------------------------------------------
if [ "$SKIP_BUILD" != "1" ]; then
    echo "session: building guest + image (zig build, zig build image)"
    zig build
    zig build image
    echo "session: building the SPIKE VMRunner (host file channel needs the custom-virtio shape)"
    swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
    codesign --force --sign - --entitlements host/vm-runner/entitlements.plist "$RUNNER"
fi

[ -x "$RUNNER" ] || { echo "session: ERROR — $RUNNER is missing; run 'just session' without VIRELAI_SESSION_SKIP_BUILD=1 (or build it with 'swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE')"; exit 1; }
[ -f "$ROOT/artifacts/disk.img" ] || { echo "session: ERROR — artifacts/disk.img is missing; create it with 'zig build image'"; exit 1; }

# --- 1b. mint/validate the profile bundle BEFORE seeding --------------------
# --profile-init exits after create-or-load: an absent path is minted, an
# existing bundle is validated, and a corrupt manifest refuses by name here
# rather than mid-boot.
"$RUNNER" --profile "$PROFILE" --profile-init
# Pin the boot base image absolutely so the bundle boots from any cwd.
python3 - "$PROFILE/config.json" "$ROOT/artifacts/disk.img" <<'PY'
import json, os, sys, tempfile
cfg_path, base = sys.argv[1], os.path.abspath(sys.argv[2])
with open(cfg_path) as f:
    cfg = json.load(f)
if cfg.get("baseImage") != base:
    cfg["baseImage"] = base
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cfg_path))
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, cfg_path)
PY
# One-time migration: a pre-M115c default share moves into the bundle.
if [ -z "${VIRELAI_SESSION_SHARE:-}" ] && [ -d "$ROOT/artifacts/session-share" ] && [ -z "$(ls -A "$SHARE" 2>/dev/null)" ]; then
    echo "session: migrating artifacts/session-share into $SHARE"
    cp -R "$ROOT/artifacts/session-share/." "$SHARE/"
fi

# --- 1c. format the profile's vlfs.img data disk (M120a #2558) ----------
# A fresh bundle has no vlfs.img at all (the mint only creates dirs), so
# the guest's /disk mount refuses not_vlfs and nothing persists. Format it
# once with the same mkfs.vlfs the VLFS gates drive. The --check probe is
# the gate: an absent/unformatted image is minted, a clean volume (even
# one with an unreplayed journal — informational, rc 0) is kept, and a
# structurally CORRUPT volume is warned about but NEVER reformatted —
# silently rewriting it would destroy data.
MKFS="$ROOT/.build/go/mkfs.vlfs"
if [ ! -x "$MKFS" ] && [ -f "$ROOT/tools/go/vlfs/build.sh" ]; then
    bash "$ROOT/tools/go/vlfs/build.sh" || true
fi
VLFS_IMG="$PROFILE/vlfs.img"
if [ -x "$MKFS" ]; then
    vlfs_check="$("$MKFS" --check "$VLFS_IMG" 2>&1)" || true
    if [ ! -f "$VLFS_IMG" ] || printf '%s' "$vlfs_check" | grep -q 'not_vlfs'; then
        "$MKFS" "$VLFS_IMG" && echo "session: formatted $VLFS_IMG (VLFS data disk)"
    elif ! printf '%s' "$vlfs_check" | grep -q 'check: clean'; then
        echo "session: WARNING — $VLFS_IMG fails its VLFS check and was NOT reformatted (that would destroy data):"
        printf '%s\n' "$vlfs_check" | head -5 | sed 's/^/session:           /'
    fi
else
    echo "session: WARNING — mkfs.vlfs unavailable (no .build/go/mkfs.vlfs and tools/go/vlfs/build.sh missing or failed); the profile's data disk stays unformatted and /disk will not mount"
fi

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
[ -f "$ROOT/image/fonts/Inter-BoldItalic.ttf" ] && cp "$ROOT/image/fonts/Inter-BoldItalic.ttf" "$SHARE/INTERBI.TTF"
[ -f "$ROOT/image/fonts/FiraCode-Regular.ttf" ] && cp "$ROOT/image/fonts/FiraCode-Regular.ttf" "$SHARE/FIRACODE.TTF"
# M86d: the appkit dialog's tinted chrome glyphs share this companion face.
[ -f "$ROOT/image/fonts/VirelaiChrome-Regular.ttf" ] && cp "$ROOT/image/fonts/VirelaiChrome-Regular.ttf" "$SHARE/CHROME.TTF"
# M99l (#2189): the font registry manifest. Go consumers read /host/FONTS.TXT;
# the frozen Zig engine ignores it (ADR 0034).
[ -f "$ROOT/image/fonts/fonts.txt" ] && cp "$ROOT/image/fonts/fonts.txt" "$SHARE/FONTS.TXT"
# M99m (#2190) coverage faces: the serif role primary and the CJK cascade tail.
[ -f "$ROOT/image/fonts/NotoSerif-Regular.ttf" ] && cp "$ROOT/image/fonts/NotoSerif-Regular.ttf" "$SHARE/NOTOSERF.TTF"
[ -f "$ROOT/image/fonts/NotoSansJP-Regular.ttf" ] && cp "$ROOT/image/fonts/NotoSansJP-Regular.ttf" "$SHARE/NOTOCJK.TTF"

# stage_go_app <NAME.ELF> — the M122a incremental build step. The plan above
# already knows each app's freshness: a `fresh` ELF is never rebuilt and a
# share copy identical to .build/go is never rewritten, so a warm run stages
# nothing. `stale`/`missing` go through ensure-guest-elf, which rebuilds,
# stamps, and re-checks (a builder that writes the wrong bytes still fails
# closed). A failed builder never copies a stale output or reports success;
# a binary already on a persistent share remains user-owned — exec still
# validates that image and reports a real load failure.
stage_go_app() {
    local app="$1" script status out
    script="$ROOT/$(go_app_builder "$app")"
    if [ "$SKIP_BUILD" = "1" ]; then
        # The skip flag covers the Go builders too: reuse the last .build/go
        # output verbatim — or the share's own copy when even that is gone.
        if [ -s "$ROOT/.build/go/$app" ]; then
            :
        elif [ -s "$SHARE/$app" ]; then
            echo "session: $app kept from the share (build skipped)"
            return 0
        else
            echo "session: WARNING — $app unavailable: no prior build (VIRELAI_SESSION_SKIP_BUILD=1)"
            return 0
        fi
    else
        status="$(app_status "$app")"
        if [ "$status" != "fresh" ]; then
            local var="ENSURE_GUEST_ELF_BUILD_${app%.ELF}"
            if [ ! -f "$script" ] && [ -z "${!var:-}" ]; then
                echo "session: WARNING — $app unavailable: missing builder $script"
                return 0
            fi
            echo "session: building $app — $status (bash $(go_app_builder "$app"))"
            if ! out="$(bash "$ENSURE" ensure "${app%.ELF}" 2>&1)"; then
                # The builder exiting nonzero keeps ensure's own "cannot
                # stamp" from firing; an exit-0 builder with no output dies
                # at the stamp step instead. Name which happened.
                case "$out" in
                    *"ensure-guest-elf: cannot stamp"*) reason="builder produced no binary" ;;
                    *) reason="builder failed" ;;
                esac
                echo "session: WARNING — $app unavailable: $reason ($script)"
                printf '%s\n' "$out" | tail -8 | sed 's/^/session:           /'
                return 0
            fi
        fi
        if [ ! -s "$ROOT/.build/go/$app" ]; then
            echo "session: WARNING — $app unavailable: builder produced no binary ($script)"
            return 0
        fi
    fi
    if [ -f "$SHARE/$app" ] && cmp -s "$ROOT/.build/go/$app" "$SHARE/$app"; then
        echo "session: $app up-to-date"
    else
        cp "$ROOT/.build/go/$app" "$SHARE/$app"
        echo "session: staged $app"
    fi
}

# The GO seat (M59, issue #1298): the compiled `wm` default is `gotabwm`, so
# a default boot looks for GOTABWM.ELF ON THE SHARE. Build it with the
# GOOS=virelai fork toolchain and stage it; if that is unavailable the
# session still opens, with an honest warning and the Zig TABWM fallback (the
# rc below says which). The default first-boot workspace also needs GOSH.ELF.
GO_SEAT_STAGED=0
if [ "${VIRELAI_SESSION_NO_GOTABWM:-0}" != "1" ]; then
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        case "$app" in GOUPD.ELF|AGENTD.ELF) continue ;; esac
        stage_go_app "$app"
    done <<< "$GO_APPS"
    if [ -s "$SHARE/GOTABWM.ELF" ] && [ -s "$SHARE/GOSH.ELF" ]; then
        GO_SEAT_STAGED=1
    else
        echo "session: WARNING — the Go seat or its GOSH.ELF first-boot shell is unavailable."
        echo "session:           build commands: 'bash tools/go/build-gotabwm.sh' and 'bash tools/go/build-gosh.sh'."
        echo "session:           if the fork toolchain is missing, provision it with 'bash tools/go/apply.sh && just go-toolchain'."
        echo "session:           the Zig TABWM seat is the fallback when this share has no .virelairc."
    fi
fi

# The persistence tools (M120a #2558): not manifest apps — the credentials
# below bind to them, so a session without them carries dead rows. GOUPD.ELF
# signs staged OS updates under the `os-update` row; AGENTD.ELF serves the
# agent channel under `agent-hmac`. They stage outside the NO_GOTABWM
# guard: --no-gotabwm disables the SEAT, not the machine's own wiring.
# Same contract as the manifest apps: warn-only, never copy a stale output.
for app in GOUPD.ELF AGENTD.ELF; do
    stage_go_app "$app"
done

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

# --- 3c. the session credentials (M114c #2456, M120a #2558) -------------
# Four credentials as SECRETS.TXT rows, all idempotent: an existing row
# is KEPT (the credential persists across sessions, matching the share's
# persistence), an existing file keeps every other row, and no value is
# ever logged.
#   vsock-ctl   uid_system, app-unbound — the ctl channel's HMAC key; the
#               host reads the share's file directly so the row serves on
#               EITHER share transport (ADR 0056 D2).
#   os-update   the Ed25519 seed GOUPD.ELF signs staged updates with
#               (app-bound; the profile's config.updatePubkey pins the
#               public half — derived below, never minted twice).
#   agent-hmac  the agent channel key (ADR 0052 D4) — TWO same-key rows
#               since M173d (#3159): uid_agent for AGENTD.ELF, uid_user
#               for GOTOP.ELF's receipt verification (the sys_secret_get
#               uid scope, the live-hostint.spec split).
#   host-int    the M108 lanes' VHI1 HMAC key, bound to GOTABWM.ELF
#               (M114c, ADR 0051) — provisioned only under --host-int.
# Every bound row also needs its app named uid_system-owned in OWNERS.TXT
# (ADR 0024 D8). On a --save-capable boot the bound rows still exist but
# are unservable by design — OWNERS.TXT and the bound-secret path live on
# the cvc queue-5 arming point (the M115g transport split).
SECRETS_FILE="$SHARE/SECRETS.TXT"
OWNERS_FILE="$SHARE/OWNERS.TXT"
secrets_v1=1
owners_v1=1
if [ -f "$SECRETS_FILE" ] && [ "$(head -n1 "$SECRETS_FILE")" != "#v1" ]; then
    secrets_v1=0
    echo "session: WARNING — $SECRETS_FILE is not a #v1 secrets file; no session credentials were provisioned (vsock-ctl sessions will refuse no_credential)"
fi
if [ -f "$OWNERS_FILE" ] && [ "$(head -n1 "$OWNERS_FILE")" != "#v1" ]; then
    owners_v1=0
    echo "session: WARNING — $OWNERS_FILE is not a #v1 owners file; app-bound credentials may not be served"
fi

# ensure_secret <name> <uid> [binding] — mint a fresh random row when the
# name is absent; keep an existing row verbatim (warn when its uid is not
# the one the channel requires).
ensure_secret() {
    local name="$1" uid="$2" bind="${3:-}"
    [ "$secrets_v1" = "1" ] || return 0
    if grep -q "^${name}"$'\t' "$SECRETS_FILE" 2>/dev/null; then
        if ! grep -q "^${name}"$'\t'"${uid}"$'\t' "$SECRETS_FILE" 2>/dev/null; then
            echo "session: WARNING — the ${name} row in $SECRETS_FILE does not carry uid ${uid}; the channel that needs it will refuse"
        fi
        return 0
    fi
    local key
    key="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
    [ -f "$SECRETS_FILE" ] || printf '#v1\n' > "$SECRETS_FILE"
    if [ -n "$bind" ]; then
        printf '%s\t%s\t%s\t%s\n' "$name" "$uid" "$key" "$bind" >> "$SECRETS_FILE"
        echo "session: provisioned the ${name} credential in $SECRETS_FILE (app-bound to $bind)"
    else
        printf '%s\t%s\t%s\n' "$name" "$uid" "$key" >> "$SECRETS_FILE"
        echo "session: provisioned the ${name} credential in $SECRETS_FILE"
    fi
}

# ensure_secret_uid <name> <uid> <binding> — a second-principal row for a
# credential another uid already carries: the (name,uid) pair is minted by
# REUSING the existing row's key (one credential, several readers — the
# M173d agent-hmac split) and kept verbatim once present. A no-op when the
# name is absent entirely; ensure_secret owns the first mint.
ensure_secret_uid() {
    local name="$1" uid="$2" bind="$3"
    [ "$secrets_v1" = "1" ] || return 0
    grep -q "^${name}"$'\t'"${uid}"$'\t' "$SECRETS_FILE" 2>/dev/null && return 0
    local key
    key="$(awk -F'\t' -v n="$name" '$1 == n { print $3; exit }' "$SECRETS_FILE" 2>/dev/null)"
    [ -n "$key" ] || return 0
    printf '%s\t%s\t%s\t%s\n' "$name" "$uid" "$key" "$bind" >> "$SECRETS_FILE"
    echo "session: provisioned the ${name} uid-${uid} row in $SECRETS_FILE under the existing credential (app-bound to $bind)"
}

# ensure_owner <app> — the uid_system OWNERS.TXT row a bound credential
# needs to be served to that app (same keep-and-warn contract).
ensure_owner() {
    local app="$1"
    [ "$owners_v1" = "1" ] || return 0
    if ! grep -q "^${app}"$'\t' "$OWNERS_FILE" 2>/dev/null; then
        [ -f "$OWNERS_FILE" ] || printf '#v1\n' > "$OWNERS_FILE"
        printf '%s\t644\t0\t-\n' "$app" >> "$OWNERS_FILE"
    elif ! grep -q "^${app}"$'\t'"644"$'\t'"0"$'\t' "$OWNERS_FILE" 2>/dev/null; then
        echo "session: WARNING — $OWNERS_FILE owns $app to a non-system uid; sys_secret_get will refuse its bound rows (ADR 0024 D8)"
    fi
}

ensure_secret vsock-ctl 0
ensure_secret os-update 1000 GOUPD.ELF
# The uid_agent clone runs FIRST: on a pre-M173d share the kept uid_user
# row's key is re-scoped to the daemon's principal (the credential survives
# the migration — receipts stay verifiable on every reader); on a fresh
# share the clone is a no-op and ensure_secret mints the row instead.
ensure_secret_uid agent-hmac 2000 AGENTD.ELF
ensure_secret agent-hmac 2000 AGENTD.ELF
ensure_secret_uid agent-hmac 1000 GOTOP.ELF
ensure_owner GOUPD.ELF
ensure_owner GOTOP.ELF
ensure_owner AGENTD.ELF
if [ "$HOST_INT" = "1" ]; then
    ensure_secret host-int 1000 GOTABWM.ELF
    ensure_owner GOTABWM.ELF
fi

# Pin config.updatePubkey to the os-update row's public half so
# --apply-update verifies GOUPD's signatures without --update-key. The
# seed is read from whatever row survived (ours or a user's), derived
# with agentctl's stdlib Ed25519, and only FILLS an absent pin — a
# mismatch is named, never silently rewritten.
if [ "$secrets_v1" = "1" ]; then
    python3 - "$PROFILE/config.json" "$SECRETS_FILE" "$ROOT/tools/agentctl" <<'PY' || \
        echo "session: WARNING — could not pin config.updatePubkey from the os-update row; --apply-update will need --update-key"
import json, os, sys, tempfile
cfg_path, secrets_path, agentctl_dir = sys.argv[1:4]
seed = None
try:
    with open(secrets_path) as f:
        for line in f:
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 3 and fields[0] == "os-update":
                seed = fields[2]
                break
except OSError:
    pass
if seed is None:
    sys.exit(0)
sys.path.insert(0, agentctl_dir)
import agentctl
pub = agentctl.ed_public_key(bytes.fromhex(seed)).hex()
with open(cfg_path) as f:
    cfg = json.load(f)
if not cfg.get("updatePubkey"):
    cfg["updatePubkey"] = pub
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cfg_path))
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, cfg_path)
    print("session: pinned config.updatePubkey to the os-update row's public key")
elif cfg["updatePubkey"] != pub:
    print("session: WARNING — config.updatePubkey does not match the os-update "
          "row's public key; --apply-update would refuse sig_invalid (fix one "
          "of them by hand)", file=sys.stderr)
PY
fi

# --- 4. boot ----------------------------------------------------------------
if [ "$PROVISION_ONLY" = "1" ]; then
    echo "session: provisioning complete profile=$PROFILE share=$SHARE save_capable=$SAVE_CAPABLE"
    exit 0
fi

if [ "$RESUME" = "1" ] && [ ! -f "$PROFILE/saved-state/state.vzsave" ]; then
    echo "session: ERROR — --resume needs a suspended machine, but $PROFILE/saved-state/state.vzsave is absent (nothing has suspended into this profile)" >&2
    exit 1
fi

# The only per-run scratch is run/session-start.txt inside the bundle; EFI
# vars, the boot overlay, vlfs.img, share/ and machine-id.bin persist.
# The Go seat's startup probe waits for a focus-loss event after opening its
# own window. In an automated gate the harness focuses the monitor window;
# provide the same one-shot handoff here so a fresh desktop reaches its shell
# workspace without requiring a startup click.
mkdir -p "$PROFILE/run"
printf '%s\n' 'dui focus 0' > "$PROFILE/run/session-start.txt"

# Package the runner INSIDE the profile at a stable path, stamped with the
# manifest's identity as CFBundleIdentifier. A stable path + a stable bundle
# id + a signature refreshed only when the binary changes is what keeps
# macOS TCC treating every session as ONE responsible process. Launch the
# executable directly so the terminal owns/waits for the VM process (not
# `open`'s helper). The raw VMRunner remains the CLI gate entrypoint.
SESSION_APP="$PROFILE/VirelaiOS.app"
mkdir -p "$SESSION_APP/Contents/MacOS"
python3 - "$ROOT/host/vm-runner/Resources/Session-Info.plist" \
          "$SESSION_APP/Contents/Info.plist" "$PROFILE/manifest.json" <<'PY'
import json, plistlib, sys
with open(sys.argv[1], "rb") as f:
    plist = plistlib.load(f)
with open(sys.argv[3]) as f:
    plist["CFBundleIdentifier"] = json.load(f)["identity"]
with open(sys.argv[2], "wb") as f:
    plistlib.dump(plist, f)
PY
if ! cmp -s "$RUNNER" "$SESSION_APP/Contents/MacOS/VirelaiOS" || ! codesign --verify "$SESSION_APP" >/dev/null 2>&1; then
    cp "$RUNNER" "$SESSION_APP/Contents/MacOS/VirelaiOS"
    codesign --force --sign - --entitlements "$ROOT/host/vm-runner/entitlements.plist" "$SESSION_APP"
fi

# M128c (#2607): the assembled app is the .virelaivm document handler —
# register it with LaunchServices so a Finder double-click resolves it.
# A package-nested bundle is never scanned into the LS database on its
# own and session.sh execs the binary directly (not via `open`), so the
# handler registration has to happen here. warn-only: a failed register
# keeps the session bootable, just not document-openable.
LSREGISTER="$(command -v lsregister || echo /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister)"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$SESSION_APP" >/dev/null 2>&1 \
        && echo "session: registered the .virelaivm document handler ($SESSION_APP)" \
        || echo "session: WARNING — lsregister -f $SESSION_APP failed; double-click open will not resolve"
fi

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

# The share transport is the M115g split made a flag (M120a #2558):
# --cvc-file is the custom-virtio device VZ save/restore refuses, so a
# save-capable run rides the bundle's share on Apple's virtio-fs instead
# — and the cvc-only host lanes go with the transport they need.
SHARE_FLAGS=()
LANE_FLAGS=()
if [ "$SAVE_CAPABLE" = "1" ]; then
    SHARE_FLAGS+=(--virtio-fs "$SHARE")
    if [ "$HOST_INT" = "1" ]; then
        echo "session: --save-capable rides virtio-fs: the cvc-only host lanes (clipboard/drop/notify/outbox) are OFF this boot"
    fi
else
    SHARE_FLAGS+=(--cvc-file "$SHARE")
    if [ "$HOST_INT" = "1" ]; then
        LANE_FLAGS+=(--host-clipboard --host-drop --host-notify --host-outbox)
    fi
fi
if [ "$SOUND" = "1" ]; then LANE_FLAGS+=(--sound); fi
if [ "$NET_NAT" = "1" ]; then LANE_FLAGS+=(--net-nat); fi

# --vsock --vsock-ctl arm the virelai-ctl/1 channel on every posture: the
# PWR menu's Suspend then gets an honest verdict — `unsupported` on the
# cvc transport, a real save on virtio-fs — instead of `no_device`.
VSOCK_FLAGS=(--vsock --vsock-ctl)

# A resume continues a machine mid-syscall: the first-boot focus script
# has no monitor to talk to (and its 'gotabwm: win focus' anchor never
# reprints), so the scripted-input flags stay off the resume command.
BOOT_INPUT_FLAGS=()
RESUME_FLAGS=()
if [ "$RESUME" = "1" ]; then
    RESUME_FLAGS+=(--resume "$PROFILE")
else
    BOOT_INPUT_FLAGS+=(--script "$PROFILE/run/session-start.txt" --script-after 'gotabwm: win focus')
fi

cat <<EOF

>>>>>>>>>> VirelaiOS session <<<<<<<<<<

A 1280x720 VM window is opening. The default Go seat (GOTABWM.ELF) starts a
first-boot GOSH shell workspace when there is no saved session. The Zig TABWM
seat remains available with \`settings set wm tabwm\`.

  * the seat's markers and the guest shell output are in
      artifacts/session-serial.log
EOF
if [ "$HOST_INT" = "1" ] && [ "$SAVE_CAPABLE" != "1" ]; then
    cat <<EOF
  * host lanes armed: clipboard + file-drop + notify + export (Integration
    menu has live suspend/resume toggles + "Send File to INBOX";
    --no-host-int disarms). Exports land in ~/Downloads. macOS may ask
    once for notification permission.
EOF
fi
if [ "$SAVE_CAPABLE" = "1" ]; then
    cat <<EOF
  * share posture: virtio-fs (save-capable) — the PWR menu's Suspend and
    snapshots are armed; the cvc-only host lanes are OFF this boot.
    Relaunch without --save-capable/--resume for the
    clipboard/drop/notify/outbox lanes and the app-bound credentials
    (host-int, os-update, agent-hmac).
EOF
else
    cat <<EOF
  * share posture: cvc-file — the host lanes and every app-bound
    credential are live; the PWR menu's Suspend answers 'unsupported'
    (a cvc share cannot be saved). Relaunch with --save-capable for
    save/restore, or --resume to continue a suspended machine.
EOF
fi
cat <<EOF

The guest serial log is written to artifacts/session-serial.log.
The machine persists in: $PROFILE
  (boot overlay, EFI vars, vlfs.img, share/, machine id, saved-state/)
Close the VM window, choose Quit VirelaiOS (Cmd-Q), or press Ctrl-C here
to stop the VM. Rerun this command to relaunch; VM RAM is not persisted
unless you suspend it (PWR menu, --save-capable posture).

EOF

# A GUI parent's bundle identity belongs to that app, not this CLI runner.
# Do not let macOS associate the independent VM window with Factory/Terminal.
env -u __CFBundleIdentifier "$SESSION_APP/Contents/MacOS/VirelaiOS" \
    --profile "$PROFILE" \
    "${RESUME_FLAGS[@]}" \
    --serial "$SERIAL_LOG" \
    "${SHARE_FLAGS[@]}" \
    "${VSOCK_FLAGS[@]}" \
    "${BOOT_INPUT_FLAGS[@]}" \
    --display --input --host-session \
    "${LANE_FLAGS[@]}" \
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
