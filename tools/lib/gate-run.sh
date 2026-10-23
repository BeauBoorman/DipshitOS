#!/usr/bin/env bash
#
# gate-run.sh -- per-run isolation for live (class-B) gates.
# Issue #523 item 2, claim 6637. Source this from a verify-live-* script:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/gate-run.sh"   # from tools/
#   gate_begin live-net-tcp
#   ... run VMRunner with "${GATE_RUNNER_ARGS[@]}", --serial "$RUN_DIR/vm-serial.log",
#       scratch files under "$RUN_DIR", evidence copied back to artifacts/ ... (optionally
#       gate_seed_share to arm the host file channel seeded with the app bundle) ...
#   gate_end
#
# gate_begin NAME:
#   - creates a private RUN_DIR (mktemp -d); two concurrent runs of the same
#     or different gates never share writable state;
#   - fills GATE_RUNNER_ARGS: --overlay-base artifacts/disk.img --vars <vars>
#     (macOS 27 DiskImageKit stacked image — M34 HF6 issue #740: the ONE
#     shared read-only boot image; every gate attaches the same canonical
#     artifacts/disk.img opened READ-ONLY as the base; the loader's own
#     pre-exit writes (BOOTED.TXT / MEMMAP.TXT / LOADER.TXT) plus all guest
#     writes land in a throwaway per-run ASIF overlay the runner deletes at
#     exit). No per-gate disk copy, no gate_shared_disk_lock: the base is
#     never written, so concurrent gates cannot collide on it. The image
#     build is atomic (make-image.sh writes IMAGE.tmp then renames), so a
#     gate that rebuilds artifacts/disk.img while another attaches it always
#     sees a complete image.
# gate_seed_share:
#   - arms the guest host file channel for this gate: creates $RUN_DIR/share,
#     copies the app bundle (zig-out/bin) into it, generates the ELF/.SO
#     fixtures (HELLO.ELF, CRASH.ELF, LD.SO, LIBUI.SO, ...) fresh, drops the
#     APPS.TXT manifest in, and appends --cvc-file "$SHARE" to
#     GATE_RUNNER_ARGS. A gate that execs a guest app MUST
#     call this; gates that only read the serial port can skip it.
# gate_end:
#   - removes RUN_DIR unless VIRELAI_KEEP_RUN=1 (post-mortem escape hatch).
# gate_begin also installs INT/TERM traps that run gate_end and exit
#   128+sig, so a signal aimed at the harness shell still tears down the
#   staging dir instead of leaking it (or, for INT, being swallowed while a
#   foreground runner holds the wait).
#
# Evidence policy: copy what you need back into artifacts/ BEFORE gate_end
# using the gate's canonical names. Two concurrent instances of the SAME
# gate may race on those canonical copies (last writer wins) but can no
# longer corrupt each other's runs.

set -euo pipefail

RUN_DIR=""
GATE_NAME=""
GATE_RUNNER_ARGS=()
SHARE=""

# --- the shell floor (issue #1338) -------------------------------------------
# A class-B harness must never be able to report a PASS it did not earn. Under
# `set -u`, bash < 4.4 expands an EMPTY array (`"${VGATE_NOTES[@]}"` with no
# notes -- most specs) into a FATAL error whose exit status is ZERO: the
# harness dies mid-plan, after the build preamble and before any boot, and the
# caller reads PASS for a gate that never ran. Observed live 2026-09-15 with
# /bin/bash 3.2.57 -- macOS's own, which is what a non-interactive shell gets
# when /usr/bin leads PATH: `PASS go-fart (16s)`, no VM, no serial log, no
# asserts evaluated. Rather than audit every array expansion in every harness
# for a 20-year-old shell, the floor is named once and checked at the door.
#
# gate_assert_modern_bash [MAJOR MINOR] -- 0 when the version (default: the
# running shell) is >= 4.4, else a loud 2. The explicit-version form is what
# lets tools/gate/test-gate-run.sh pin the boundary on a modern CI shell.
gate_assert_modern_bash() {
    local major="${1:-${BASH_VERSINFO[0]:-0}}"
    local minor="${2:-${BASH_VERSINFO[1]:-0}}"
    if [ "$major" -gt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -ge 4 ]; }; then
        return 0
    fi
    echo "gate-run: refusing to run under bash ${BASH_VERSION:-$major.$minor} — the gate harness needs >= 4.4." >&2
    echo "  On bash < 4.4 an empty-array expansion under 'set -u' is fatal AND exits ZERO, so a" >&2
    echo "  harness that dies there reports PASS for a gate that never booted (issue #1338)." >&2
    echo "  Fix the shell first: source tools/env-check.sh (puts /opt/homebrew/bin ahead of /usr/bin)." >&2
    return 2
}

gate_begin() {
    GATE_NAME="$1"
    # Base directory is overridable for experiments/debugging:
    #   VIRELAI_RUN_DIR_BASE=<dir>  (default: ${TMPDIR:-/tmp})
    local base="${VIRELAI_RUN_DIR_BASE:-${TMPDIR:-/tmp}}"
    mkdir -p "$base"
    RUN_DIR="$(mktemp -d "$base/virelai-${GATE_NAME}.XXXXXX")"
    # Run-dir teardown on signal exits. The caller's EXIT trap already runs
    # gate_end on every exit bash reaches — but make it a contract: translate
    # INT/TERM into an exit that runs gate_end first and reports the
    # conventional 128+sig status. Caveats are bash's, not ours: a signal
    # while a foreground runner holds the wait is deferred until the child
    # exits (TERM) — or discarded entirely when the child exits normally
    # (INT) — and SIGKILL is untrappable by construction, so a killed gate
    # can still strand RUN_DIR. This covers the paths that do reach a trap:
    # signals between commands, and Ctrl-C delivery where the runner dies of
    # SIGINT with us. RUN_DIR is per-invocation so its lifetime is exactly
    # this process; gate_end is idempotent — the caller's EXIT trap
    # re-entering it is a no-op — and VIRELAI_KEEP_RUN stays honored.
    trap 'gate_end 2>/dev/null || true; exit 130' INT
    trap 'gate_end 2>/dev/null || true; exit 143' TERM
    # M34 HF6 (issue #740): attach the CANONICAL artifacts/disk.img as the
    # read-only overlay base — no private copy (the boot volume is never
    # written by the guest; the loader's pre-exit evidence writes land in
    # the per-run ASIF overlay).
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    [ -f "$repo_root/artifacts/disk.img" ] || { echo "gate-run: ERROR — artifacts/disk.img missing (run 'zig build image' first)" >&2; exit 1; }
    if [ -f "$repo_root/artifacts/efi-vars.bin" ]; then
        cp "$repo_root/artifacts/efi-vars.bin" "$RUN_DIR/efi-vars.bin"
    else
        : > "$RUN_DIR/efi-vars.bin"
    fi
    GATE_RUNNER_ARGS=(--overlay-base "$repo_root/artifacts/disk.img" --vars "$RUN_DIR/efi-vars.bin")
}

# gate_prepare_share -- create the empty private share directory.
gate_prepare_share() {
    [ -n "$RUN_DIR" ] || { echo "gate-run: gate_arm_share called before gate_begin" >&2; exit 1; }
    SHARE="$RUN_DIR/share"
    mkdir -p "$SHARE"
}

# gate_arm_share -- arm the custom-virtio host file channel with an EMPTY
# private share (for gates that only need the channel, not the app bundle).
gate_arm_share() {
    gate_prepare_share
    GATE_RUNNER_ARGS+=(--cvc-file "$SHARE")
    echo "gate-run: share armed (empty) at $SHARE"
}

# gate_arm_virtiofs_share -- arm Apple's standard VirtioFS device with an
# EMPTY private share. This is independent of custom virtio and saveable by VZ.
gate_arm_virtiofs_share() {
    gate_prepare_share
    GATE_RUNNER_ARGS+=(--virtio-fs "$SHARE")
    echo "gate-run: VirtioFS share armed (empty) at $SHARE"
}

# gate_seed_share_contents -- seed the app bundle and shared static assets.
# Used with either transport so the boot image contents stay identical.
gate_seed_share_contents() {
    [ -n "$SHARE" ] || { echo "gate-run: gate_seed_share_contents called before share setup" >&2; exit 1; }
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    # 1. The compiled Zig app bundle (USER.BIN, GOCALC.ELF, ...).
    if [ -d zig-out/bin ]; then
        cp -R zig-out/bin/. "$SHARE/" 2>/dev/null || true
    fi
    # 2. Freshly generated fixtures (HELLO.ELF / CRASH.ELF via mkhello-elf,
    #    the M30/M31 dynamic-linking set via mkdyn-elf) — generated into
    #    the share so they exist even if the last `zig build image` ran
    #    before they were produced.
    if [ -f tools/mkhello-elf.py ]; then
        python3 tools/mkhello-elf.py "$SHARE/HELLO.ELF" 2>/dev/null || true
        python3 tools/mkhello-elf.py --crash "$SHARE/CRASH.ELF" 2>/dev/null || true
    fi
    if [ -f tools/mkdyn-elf.py ]; then
        python3 tools/mkdyn-elf.py "$SHARE" 2>/dev/null || true
    fi
    # 3. The desktop manifest (the guest reads /host/APPS.TXT).
    if [ -f image/apps.txt ]; then
        cp image/apps.txt "$SHARE/APPS.TXT"
    fi
    # 4. The default desktop wallpaper (the guest reads /host/WALLPAPER.QOI).
    if [ -f image/WALLPAPER.QOI ]; then
        cp image/WALLPAPER.QOI "$SHARE/WALLPAPER.QOI"
    fi
    # 4b. The launcher emblem (#2054): the same mascot QOI the Zig
    # fixtures carry, read by the Go seat at /host/SEXIBURGER.QOI.
    if [ -f user/src/lib/fixtures/qoi/mascot_64x64.qoi ]; then
        cp user/src/lib/fixtures/qoi/mascot_64x64.qoi "$SHARE/SEXIBURGER.QOI"
    fi
    # 5. TrueType fonts (Inter Regular/Bold/Italic/BoldItalic for UI,
    # Fira Code for mono). Share names frozen by M69d #1531 D1 (+ INTERBI.TTF
    # from M99o #2192): INTER.TTF, INTERB.TTF, INTERI.TTF, INTERBI.TTF,
    # FIRACODE.TTF. Zig ui.init_fonts (#1536) consumes the same names.
    if [ -f image/fonts/Inter-Regular.ttf ]; then
        cp image/fonts/Inter-Regular.ttf "$SHARE/INTER.TTF"
    elif [ -f FONTS-CHOOSE/Inter-4.1/extras/ttf/Inter-Regular.ttf ]; then
        cp FONTS-CHOOSE/Inter-4.1/extras/ttf/Inter-Regular.ttf "$SHARE/INTER.TTF"
    fi
    if [ -f image/fonts/Inter-Bold.ttf ]; then
        cp image/fonts/Inter-Bold.ttf "$SHARE/INTERB.TTF"
    elif [ -f FONTS-CHOOSE/Inter-4.1/extras/ttf/Inter-Bold.ttf ]; then
        cp FONTS-CHOOSE/Inter-4.1/extras/ttf/Inter-Bold.ttf "$SHARE/INTERB.TTF"
    fi
    if [ -f image/fonts/Inter-Italic.ttf ]; then
        cp image/fonts/Inter-Italic.ttf "$SHARE/INTERI.TTF"
    elif [ -f FONTS-CHOOSE/Inter-4.1/extras/ttf/Inter-Italic.ttf ]; then
        cp FONTS-CHOOSE/Inter-4.1/extras/ttf/Inter-Italic.ttf "$SHARE/INTERI.TTF"
    fi
    if [ -f image/fonts/Inter-BoldItalic.ttf ]; then
        cp image/fonts/Inter-BoldItalic.ttf "$SHARE/INTERBI.TTF"
    elif [ -f FONTS-CHOOSE/Inter-4.1/extras/ttf/Inter-BoldItalic.ttf ]; then
        cp FONTS-CHOOSE/Inter-4.1/extras/ttf/Inter-BoldItalic.ttf "$SHARE/INTERBI.TTF"
    fi
    if [ -f image/fonts/FiraCode-Regular.ttf ]; then
        cp image/fonts/FiraCode-Regular.ttf "$SHARE/FIRACODE.TTF"
    elif [ -f FONTS-CHOOSE/Fira_Code_v6.2/ttf/FiraCode-Regular.ttf ]; then
        cp FONTS-CHOOSE/Fira_Code_v6.2/ttf/FiraCode-Regular.ttf "$SHARE/FIRACODE.TTF"
    fi
    # 5b. The kana->kanji dictionary (M186c #3180): the packed JMdict
    #     subset (CC BY-SA 4.0) layout.IME reads at /host/KANADICT.BIN.
    if [ -f image/kanadict/KANADICT.BIN ]; then
        cp image/kanadict/KANADICT.BIN "$SHARE/KANADICT.BIN"
    fi
    echo "gate-run: share seeded at $SHARE ($(find "$SHARE" -maxdepth 1 -type f | wc -l | tr -d ' ') files, $(grep -cE '^[A-Z]' "$SHARE/APPS.TXT" 2>/dev/null || echo 0) APPS.TXT entries)"
}

# gate_seed_share -- arm the custom-virtio channel then seed its app bundle.
gate_seed_share() {
    gate_arm_share
    gate_seed_share_contents
}

# gate_seed_virtiofs_share -- arm standard VirtioFS then seed the same app
# bundle. Used by restore gates because custom virtio is not saveable by VZ.
gate_seed_virtiofs_share() {
    gate_arm_virtiofs_share
    gate_seed_share_contents
}

# gate_reset_share_state -- delete per-boot guest persistence from the
# private share so each boot of a multi-boot gate starts from a clean
# slate. M37 DQ3 (issue #839, claim 6392): M21 W11 saves WINDOWS.SAV to
# the host share ~1/s on change and restores it at shell init, so boots
# B/C sharing one $RUN_DIR/share resurrect prior-boot windows (TABHOLD
# id drift → slot ENOSPC). HISTORY.TXT is deliberately kept —
# append-ordered shell history, benign across boots.
gate_reset_share_state() {
    [ -n "$RUN_DIR" ] || { echo "gate-run: gate_reset_share_state called before gate_begin" >&2; exit 1; }
    rm -f "$SHARE/WINDOWS.SAV"
}

gate_end() {
    [ -n "$RUN_DIR" ] || return 0
    if [ "${VIRELAI_KEEP_RUN:-0}" = "1" ]; then
        echo "gate-run: keeping $RUN_DIR (VIRELAI_KEEP_RUN=1)"
    else
        rm -rf "$RUN_DIR"
    fi
    RUN_DIR=""
    SHARE=""
}

# --- shared build bootstrap + serial-echo conventions ------------------------
# Every class-B gate used to carry its own copy of the fmt/swift/codesign
# preamble and the colored-prompt echo pattern; a toolchain or prompt change
# had to land in 167 files and silently drifted (issues #895/#896 — the first
# real CI run caught two gates whose echo expectations no longer matched the
# boot transcript). Centralize the parts that are truly identical; gates keep
# their per-gate differences (fmt file lists, -DSPIKE, special images) as
# ordinary calls around these helpers.

# gate_fmt_check -- zig fmt --check the given paths (one canonical invocation).
gate_fmt_check() {
    zig fmt --check "$@"
}

# gate_build_runner -- build + ad-hoc-codesign the release VMRunner with the
# VZ entitlements. Optional extra swift flags pass through (e.g.
# -Xswiftc -DSPIKE for the custom-virtio spike build).
gate_build_runner() {
    swift build --package-path host/vm-runner --configuration release "$@"
    codesign --force --sign - --entitlements host/vm-runner/entitlements.plist \
        host/vm-runner/.build/release/VMRunner
    # The signature is the difference between a runner that boots and one that
    # cannot; assert it here, where it was just applied, rather than letting a
    # later VM boot report it as something else (see the preflight below).
    gate_assert_runner_entitled "$VZ_RUNNER_BIN"
}

# --- VZ preflight -------------------------------------------------------------
# Two class-B failures both surface at VM boot looking like something else, and
# both are cheap to name in advance:
#
#   1. A runner built with a bare `swift build` -- i.e. without gate_build_
#      runner's codesign step -- carries no entitlements. Virtualization.
#      framework then refuses it, and the failure reads like a hardware or
#      configuration problem instead of a missing signature. VGATE_NO_BUILD=1
#      makes this reachable for a stale binary nobody re-signed.
#   2. A host without Hypervisor.framework cannot boot a guest at all, and the
#      gate that fails gets blamed instead of the host. Measured 2026-09-14 on
#      GitHub's hosted runners: kern.hv_support=0 with hv_vmm_present=1 (the
#      runner is itself a guest), and a direct hv_vm_create returns
#      0xfae9400f HV_UNSUPPORTED.
#
# Note the code in (2) matters: a MIS-SIGNED hv_vm_create probe returns
# 0xfae94007 HV_DENIED instead -- a verdict about the signature standing where
# a verdict about the machine is expected. That is exactly why the entitlement
# is asserted separately here, and why docs/vz-runner.md keeps the two apart.

VZ_RUNNER_BIN="${VZ_RUNNER_BIN:-host/vm-runner/.build/release/VMRunner}"
VZ_RUNNER_ENTITLEMENT="com.apple.security.virtualization"

# gate_assert_runner_entitled [BIN] -- the runner binary must actually carry
# the Virtualization.framework entitlement in its signature.
gate_assert_runner_entitled() {
    local bin="${1:-$VZ_RUNNER_BIN}"
    if [ ! -f "$bin" ]; then
        echo "gate-run: ERROR — no runner binary at $bin" >&2
        echo "  Build it through gate_build_runner (tools/lib/gate-run.sh)," >&2
        echo "  which builds AND signs it." >&2
        return 1
    fi
    local sig
    sig="$(codesign -d --entitlements - "$bin" 2>&1 || true)"
    case "$sig" in
        *"$VZ_RUNNER_ENTITLEMENT"*) return 0 ;;
    esac
    {
        echo "gate-run: ERROR — $bin is NOT entitled with $VZ_RUNNER_ENTITLEMENT."
        echo "  A bare 'swift build' produces a binary Virtualization.framework"
        echo "  will refuse; the entitlement comes from an ad-hoc codesign pass"
        echo "  AFTER the build. Booting now would fail with an error that looks"
        echo "  like a host or configuration problem. Fix with either:"
        echo "      codesign --force --sign - \\"
        echo "          --entitlements host/vm-runner/entitlements.plist $bin"
        echo "  or rebuild through gate_build_runner. (codesign said: ${sig%%$'\n'*})"
    } >&2
    return 1
}

# --- the hypervisor capability probe ----------------------------------------
# kern.hv_support reports what the KERNEL supports; it does not ask whether a
# process can obtain a hypervisor, and it is not what the gates depend on.
# hv_vm_create is the ground truth -- Virtualization.framework is built on it
# -- so the verdict is a real call, not a proxy.
#
# tools/gate/hv-probe.c is signed with com.apple.security.hypervisor, a
# DIFFERENT key from the com.apple.security.virtualization the runner uses.
# That distinction is the whole reason HV_DENIED is treated as a harness fault
# below rather than as a capability answer.

VZ_HV_PROBE_SRC="tools/gate/hv-probe.c"
VZ_HV_PROBE_ENT="tools/gate/hv-probe.entitlements"
VZ_HV_PROBE_BIN="${VZ_HV_PROBE_BIN:-.build/hv-probe/hvprobe}"

# gate_build_hv_probe -- compile + ad-hoc-sign the probe when it is missing or
# older than its source, so a fleet sweep pays for it once. Non-zero (having
# said why) when it cannot be produced; callers fall back to the sysctl proxy.
gate_build_hv_probe() {
    if [ ! -f "$VZ_HV_PROBE_SRC" ] || [ ! -f "$VZ_HV_PROBE_ENT" ]; then
        echo "gate-run: hv probe sources missing ($VZ_HV_PROBE_SRC / $VZ_HV_PROBE_ENT)" >&2
        return 1
    fi
    if [ -x "$VZ_HV_PROBE_BIN" ] && [ "$VZ_HV_PROBE_BIN" -nt "$VZ_HV_PROBE_SRC" ]; then
        return 0
    fi
    command -v clang >/dev/null 2>&1 || { echo "gate-run: clang not found; cannot build the hv probe" >&2; return 1; }
    mkdir -p "$(dirname "$VZ_HV_PROBE_BIN")" 2>/dev/null || { echo "gate-run: cannot create $(dirname "$VZ_HV_PROBE_BIN")" >&2; return 1; }
    clang -o "$VZ_HV_PROBE_BIN" "$VZ_HV_PROBE_SRC" -framework Hypervisor >/dev/null 2>&1 \
        || { echo "gate-run: clang failed to build the hv probe" >&2; return 1; }
    codesign --force --sign - --entitlements "$VZ_HV_PROBE_ENT" "$VZ_HV_PROBE_BIN" >/dev/null 2>&1 \
        || { echo "gate-run: codesign failed on the hv probe" >&2; return 1; }
    return 0
}

# gate_report_hv_capability -- ask the host whether a hypervisor can be created
# here, print the verdict, and fail when it cannot, so the reason is stated
# instead of inferred from whatever Virtualization.framework later reports.
#
# $VZ_HV_PROBE_BIN may point at a stub; the class-A test drives the code->
# verdict mapping that way (tools/gate/test-gate-run.sh).
gate_report_hv_capability() {
    local hv vmm out code name
    hv="$(sysctl -n kern.hv_support 2>/dev/null || true)"
    vmm="$(sysctl -n kern.hv_vmm_present 2>/dev/null || true)"

    if [ ! -x "$VZ_HV_PROBE_BIN" ]; then
        gate_build_hv_probe || true
    fi

    code="" name=""
    if [ -x "$VZ_HV_PROBE_BIN" ]; then
        out="$("$VZ_HV_PROBE_BIN" 2>/dev/null || true)"
        code="$(printf '%s\n' "$out" | sed -n 's/.*HV_CODE=\(0x[0-9a-f]*\).*/\1/p' | head -1)"
        name="$(printf '%s\n' "$out" | sed -n 's/.*HV_NAME=\([A-Z_]*\).*/\1/p' | head -1)"
    fi

    if [ -n "$code" ]; then
        local hostline
        hostline="gate-run: host $(sw_vers -productVersion 2>/dev/null || echo '?')/$(uname -m)"
        hostline="$hostline; kern.hv_support=${hv:-?} hv_vmm_present=${vmm:-?}"
        hostline="$hostline; hv_vm_create -> $code (${name:-?})"
        echo "$hostline"
    else
        local hostline_fb
        hostline_fb="gate-run: host $(sw_vers -productVersion 2>/dev/null || echo '?')/$(uname -m)"
        hostline_fb="$hostline_fb; kern.hv_support=${hv:-?} hv_vmm_present=${vmm:-?}"
        hostline_fb="$hostline_fb; hv probe unavailable, falling back to the sysctl"
        echo "$hostline_fb"
    fi

    case "$name" in
        HV_SUCCESS)
            return 0 ;;
        HV_DENIED)
            {
                echo "gate-run: ERROR — the hv probe returned $code HV_DENIED."
                echo "  That is a statement about the probe's SIGNATURE, not about this"
                echo "  machine: a direct hv_vm_create needs com.apple.security.hypervisor"
                echo "  (tools/gate/hv-probe.entitlements), which gate_build_hv_probe applies"
                echo "  after the build. There is no capability verdict here — treat this as"
                echo "  a harness fault, not as 'this host cannot boot a guest'."
            } >&2
            return 1 ;;
        HV_UNSUPPORTED|HV_NO_DEVICE|HV_NO_RESOURCES|HV_ERROR|HV_FAULT|HV_BUSY|HV_BAD_ARGUMENT)
            {
                echo "gate-run: ERROR — the host refused a hypervisor ($code $name)."
                echo "  Virtualization.framework cannot boot a guest here, so every"
                echo "  class-B gate will fail regardless of the code under test."
                if [ "$vmm" = "1" ]; then
                    echo "  hv_vmm_present=1: this host is itself a VM without nested"
                    echo "  virtualization (that is the GitHub-hosted runner case)."
                fi
                echo "  See docs/vz-runner.md; class B needs a real Apple silicon host."
            } >&2
            return 1 ;;
    esac

    # A code we do not know is NOT a free pass to the weaker check: refusing to
    # guess is the whole point of asking the hypervisor directly.
    if [ -n "$code" ]; then
        {
            echo "gate-run: ERROR — the hv probe returned an unrecognised code ($code ${name:-?})."
            echo "  Refusing to guess a verdict; hv_error.h is the authority, and"
            echo "  tools/gate/hv-probe.c should be extended with this code."
        } >&2
        return 1
    fi

    # No probe at all: fall back to the kernel's own answer. Weaker, and said so.
    if [ "$hv" = "1" ]; then
        return 0
    fi
    {
        echo "gate-run: ERROR — no hv probe and kern.hv_support=${hv:-?}."
        echo "  Virtualization.framework cannot boot a guest on this host, so every"
        echo "  class-B gate will fail here regardless of the code under test."
        if [ "$vmm" = "1" ]; then
            echo "  hv_vmm_present=1: this host is itself a VM without nested"
            echo "  virtualization (that is the GitHub-hosted runner case)."
        fi
        echo "  See docs/vz-runner.md; class B needs a real Apple silicon host."
    } >&2
    return 1
}

# gate_preflight_vz [BIN] -- the one call a class-B harness makes before it
# boots anything. Tolerant of being called twice (the vgate preamble runs it
# for both the build and the VGATE_NO_BUILD=1 branches).
gate_preflight_vz() {
    gate_report_hv_capability || return 1
    gate_assert_runner_entitled "${1:-$VZ_RUNNER_BIN}"
}

# gate_serial_has_echo -- did the guest console echo the given command in the
# serial log? Accepts BOTH observed echo forms:
#   colored (interactive shell):  \x1b[32mvirelai> \x1b[0m<cmd>\r
#   plain (pre-prompt race):      <cmd>\r on its own line
# The plain form is what the scripted first keystroke produces when it lands
# while the boot-log tail is still colliding with the first prompt render
# (first CI census, issues #895/#896): the guest executed the command, but the
# shell never redrew the colored prompt for it. The machine-level effect is
# the gate's real evidence; this matcher only proves the keystrokes reached
# the console.
gate_serial_has_echo() {
    local ser="$1" cmd="$2"
    grep -a -qF -- $'\x1b[32mvirelai> \x1b[0m'"$cmd" "$ser" 2>/dev/null && return 0
    # Plain form: the command at the START of a serial line (the guest echoed
    # it before the shell redrew the prompt). Line-based via awk (literal
    # index(), not a regex) so \n, \r and \r\n endings all work.
    awk -v c="$cmd" 'index($0, c) == 1 { f = 1 } END { exit !f }' "$ser" 2>/dev/null && return 0
    return 1
}
