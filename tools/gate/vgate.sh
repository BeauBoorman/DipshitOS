#!/usr/bin/env bash
#
# vgate.sh -- the single runner for declarative class-B gate specs
# (M40 GF2, issue #937, claim #944). A spec DECLARES (meta, files, runs,
# asserts); this harness EXECUTES (one shared build preamble, gate-run.sh
# isolation, runner invoke, assert eval, report + evidence).
#
# Usage:
#   bash tools/gate/vgate.sh tools/gate/specs/<name>.spec
#
# Spec format: tools/gate/SPEC.md (frozen at GF2 close -- extend it there,
# never with one-off shell).
#
# Environment:
#   VGATE_NO_BUILD=1   skip the build preamble (dev iteration; the caller
#                      vouches the tree is already built + imaged).
#   BOOTS / VIRELAI_GATE_SUFFIX / VIRELAI_KEEP_RUN / VIRELAI_RUN_DIR_BASE
#                      honored exactly like the legacy scripts.
#
set -euo pipefail

VGATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$VGATE_DIR/../.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

# --- the shell floor (issue #1338) -------------------------------------------
# A gate that cannot fail is not a gate: gate_assert_modern_bash refuses the
# shells where this harness's failure mode is a false PASS (tools/lib/
# gate-run.sh has the mechanism). It runs before anything else, so a refusal
# costs nothing -- no build, no boot, no report claiming otherwise.
gate_assert_modern_bash || exit $?

[ $# -eq 1 ] || { echo "vgate: usage: bash tools/gate/vgate.sh <spec>" >&2; exit 2; }
SPEC="$1"
[ -f "$SPEC" ] || { echo "vgate: spec not found: $SPEC" >&2; exit 2; }

# --- plan state (filled by the spec via the DSL below) -----------------------
VGATE_NAME="" VGATE_DESC="(no description)" VGATE_SHARE="none"
VGATE_FMT="boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig"
VGATE_RUNNER_FLAGS="" VGATE_REPEAT=1 VGATE_REPEAT_ENV=""
VGATE_NOTES=() VGATE_FILE_NAMES=() VGATE_FILE_BODIES=()
VGATE_SETUP_PY=() VGATE_RUN_TAGS=() VGATE_RUN_FLAGS=() VGATE_ALLOW_RC=() VGATE_ASSERTS=()
VGATE_CLIENT_TAGS=() VGATE_CLIENT_ARGS=()
# ADR 0059 (M131b #2639): warm-checkpoint legs. VGATE_CKPT_* hold the
# declared base boots; the VGATE_RUN_* triples hold each leg's checkpoint
# tag, strict pin and deliberate-corruption knob ("" when the leg is cold).
VGATE_CKPT_TAGS=() VGATE_CKPT_FLAGS=() VGATE_CKPT_SETTLE=()
VGATE_RUN_FROM_CKPT=() VGATE_RUN_STRICT=() VGATE_RUN_CORRUPT=()

# --- the false-PASS guard, stage 1 (issue #1338) ------------------------------
# Installed BEFORE the spec is sourced, because sourcing runs untrusted spec
# code: a stray `exit 0` there used to end the harness with status 0, which the
# fleet reads as PASS. VGATE_COMPLETED is set only on the intended exit path
# (past both the run loop and the assert engine), so anything that leaves early
# is forced non-zero here. The stage-2 trap below adds the evidence teardown
# (gate_end) once there is a run dir to tear down.
VGATE_COMPLETED=0
trap 'if [ "${VGATE_COMPLETED:-0}" != 1 ]; then echo "vgate: harness exited before its result block -- FAIL (see issue #1338)" >&2; exit 2; fi' EXIT

# --- DSL (the only commands a spec may use) ----------------------------------
vgate_name() { VGATE_NAME="$1"; VGATE_DESC="${2:-$VGATE_DESC}"; }
vgate_share() { case "$1" in none|arm|seed|arm-virtiofs|seed-virtiofs) VGATE_SHARE="$1";; *) echo "vgate: bad share mode: $1" >&2; exit 2;; esac; }
vgate_fmt() { VGATE_FMT="$*"; }
vgate_runner_flags() { VGATE_RUNNER_FLAGS="$*"; }
vgate_repeat() { VGATE_REPEAT="$1"; VGATE_REPEAT_ENV="${2:-}"; }
vgate_note() { VGATE_NOTES+=("$1"); }
vgate_file() {
    # NOTE: $(cat) strips ALL trailing newlines, which glues the last
    # script line to the next forwarded chunk (observed: `echo
    # arp-phase1-ready` + `net recv` executed as one line). Re-append
    # exactly one: bodies are newline-terminated files by contract.
    local b; b="$(cat; echo x)"; b="${b%x}"
    VGATE_FILE_NAMES+=("$1"); VGATE_FILE_BODIES+=("$b");
}
vgate_setup_python() { local b; b="$(cat; echo x)"; b="${b%x}"; VGATE_SETUP_PY+=("$b"); }
vgate_checkpoint() {
    # vgate_checkpoint TAG [--settle-after MARKER] -- <runner flags...>
    # ADR 0059 D4: declares a dedicated base boot — cold boot, settle on the
    # boot-settle marker (default `tasks user-el0 reaped`) then a fresh
    # `virelai> ` prompt, then pause/save/stop into $RUN_DIR/ckpt-<TAG>/.
    # It runs no leg workload and carries no asserts.
    local tag="$1" settle="tasks user-el0 reaped"; shift
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        case "$1" in
            --settle-after)
                [ $# -ge 2 ] || { echo "vgate: vgate_checkpoint $tag: --settle-after requires a marker" >&2; exit 2; }
                settle="$2"; shift 2 ;;
            *) echo "vgate: vgate_checkpoint $tag: unknown option '$1' (only --settle-after MARKER)" >&2; exit 2 ;;
        esac
    done
    [ "${1:-}" = "--" ] || { echo "vgate: vgate_checkpoint $tag missing -- separator" >&2; exit 2; }
    shift
    # D1/D8: refuse at spec load the flags that make a configuration
    # unsaveable (the Grounding-4 custom-virtio set), the harness-owned
    # members a checkpoint cannot express, and modes a base boot cannot be.
    local f
    for f in "$@"; do
        case "$f" in
            --custom-virtio|--cvc-echo|--via-virtio|--pointer-virtio|--cvc-snap|--cvc-file|--cvc-console-file|--snapshot-after|--gpu3d-metal)
                echo "vgate: vgate_checkpoint $tag: $f arms a VZCustomVirtioDevice — unsaveable (ADR 0059 D1); this checkpoint can never be taken" >&2
                exit 2 ;;
            --usb-msd|--console|--console-tcp|--console-tcp-secret-file|--host-*|--input-*|--pointer|--pointer-after|--pointer-route|--pointer-request-trust|--net-inject*|--key-*|--chords-*)
                echo "vgate: vgate_checkpoint $tag: $f is leg-workload or host-state machinery, not a checkpoint's device shape (ADR 0059 D4/D7)" >&2
                exit 2 ;;
            --serial|--vars|--overlay-base|--virtio-fs|--vz-restore|--vz-restore-*|--profile|--profile-init|--resume|--rollback-update|--apply-update|--update-key|--script*|--expect|--terminal-marker)
                echo "vgate: vgate_checkpoint $tag: $f is harness-owned or a mode flag — the checkpoint carries device/attachment flags only" >&2
                exit 2 ;;
        esac
    done
    VGATE_CKPT_TAGS+=("$tag")
    VGATE_CKPT_SETTLE+=("$settle")
    VGATE_CKPT_FLAGS+=("$(printf '%q ' "$@")")
}
vgate_run() {
    # vgate_run TAG [--from-checkpoint CKPT [--warm-strict] [--warm-corrupt KIND]] -- <runner flags...>
    # --from-checkpoint CKPT (ADR 0059 D2): the leg restores checkpoint CKPT
    # into a fresh runner — its flag vector may carry ONLY --script* and
    # --timeout (an allow-list, not a deny-list); the device/attachment shape
    # is inherited from the checkpoint it resumes.
    # --warm-strict (D8): pin warm=restored — a restore refusal FAILs the leg
    # instead of degrading to a single cold boot.
    # --warm-corrupt KIND (evidence hooks): mangle the leg's own bundle clone
    # before restore; KIND=truncate-state halves state.vzsave.
    local tag="$1" from_ckpt="" strict=0 corrupt=""; shift
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        case "$1" in
            --from-checkpoint)
                [ $# -ge 2 ] || { echo "vgate: vgate_run $tag: --from-checkpoint requires a checkpoint tag" >&2; exit 2; }
                from_ckpt="$2"; shift 2 ;;
            --warm-strict) strict=1; shift ;;
            --warm-corrupt)
                [ $# -ge 2 ] || { echo "vgate: vgate_run $tag: --warm-corrupt requires a kind" >&2; exit 2; }
                corrupt="$2"; shift 2 ;;
            *) echo "vgate: vgate_run $tag: unknown option '$1' (use --from-checkpoint CKPT [--warm-strict] [--warm-corrupt KIND], then --)" >&2; exit 2 ;;
        esac
    done
    [ "${1:-}" = "--" ] || { echo "vgate: vgate_run $tag missing -- separator" >&2; exit 2; }
    shift
    if [ -n "$from_ckpt" ]; then
        local a
        for a in "$@"; do
            case "$a" in
                --*) case "$a" in
                        --script*|--timeout) ;;
                        *) echo "vgate: vgate_run $tag --from-checkpoint $from_ckpt: '$a' is outside the warm-leg allow-list (ADR 0059 D2: only --script*/--timeout vary; the device shape is inherited)" >&2
                           exit 2 ;;
                     esac ;;
            esac
        done
    elif [ "$strict" != 0 ] || [ -n "$corrupt" ]; then
        echo "vgate: vgate_run $tag: --warm-strict/--warm-corrupt require --from-checkpoint" >&2; exit 2
    fi
    case "$corrupt" in
        ""|truncate-state) ;;
        *) echo "vgate: vgate_run $tag: unknown --warm-corrupt kind '$corrupt' (only truncate-state)" >&2; exit 2 ;;
    esac
    VGATE_RUN_TAGS+=("$tag")
    VGATE_RUN_FLAGS+=("$(printf '%q ' "$@")")
    VGATE_RUN_FROM_CKPT+=("$from_ckpt")
    VGATE_RUN_STRICT+=("$strict")
    VGATE_RUN_CORRUPT+=("$corrupt")
}
vgate_allow_rc() {
    # vgate_allow_rc TAG RC... -- allow specific runner exit code(s) for a tag (default: 0)
    local tag="$1"; shift
    VGATE_ALLOW_RC+=("${tag}"$'\x1f'"$*")
}
vgate_assert() {
    # vgate_assert TAG KIND [args...] -- kinds: serial-contains STR
    # serial-contains-file FILE | serial-count STR MIN | serial-exact STR N
    # serial-absent STR | serial-echo CMD | output-contains STR |
    # client-contains STR | capture-equals FILE FIXTURE | capture-empty FILE |
    # share-equals RELPATH FILE-OR-LITERAL | share-contains RELPATH STR |
    # snapshot GLOB (python body on stdin) | python (body on stdin,
    # RUN_DIR/VG_SER/VG_TAG env)
    local tag="$1" kind="$2"; shift 2
    local body=""
    case "$kind" in snapshot|python) body="$(cat; echo x)"; body="${body%x}" ;; esac
    VGATE_ASSERTS+=("${tag}"$'\x1f'"${kind}"$'\x1f'"${1:-}"$'\x1f'"${2:-}"$'\x1f'"${body}")
}
vgate_client() {
    # vgate_client TAG -- FLAGS... -- launch tools/lib/vgate-client.py in the
    # BACKGROUND for the run tagged TAG (M46 RC2, issue #1069): it waits for an
    # optional serial marker, connects to --addr, sends a fixture, captures the
    # reply to $RUN_DIR/client-TAG.out, and must exit 0 or the run fails. The
    # `--` separates the tag from the hook flags. See tools/lib/vgate-client.py
    # for --addr/--after/--send-file/--send-text/--expect/--expect-fail/--timeout.
    local tag="$1"; shift
    [ "${1:-}" = "--" ] || { echo "vgate_client $tag missing -- separator" >&2; exit 2; }
    shift
    VGATE_CLIENT_TAGS+=("$tag")
    VGATE_CLIENT_ARGS+=("$(printf '%q ' "$@")")
}

# --- load the spec (unknown commands fail under set -e) ----------------------
# shellcheck disable=SC1090
source "$SPEC"
[ -n "$VGATE_NAME" ] || { echo "vgate: spec sets no vgate_name" >&2; exit 2; }
[ "${#VGATE_RUN_TAGS[@]}" -gt 0 ] || { echo "vgate: spec declares no vgate_run" >&2; exit 2; }

# --- warm-leg spec-load refusals (ADR 0059 D1/D8: the static Code=2 class) --
# These are decided from spec text and never attempted:
for i in "${!VGATE_RUN_FROM_CKPT[@]}"; do
    fck="${VGATE_RUN_FROM_CKPT[$i]}"
    [ -n "$fck" ] || continue
    if [ "$VGATE_SHARE" = arm ] || [ "$VGATE_SHARE" = seed ]; then
        echo "vgate: ${VGATE_RUN_TAGS[$i]} --from-checkpoint in a 'vgate_share $VGATE_SHARE' spec — the harness-armed --cvc-file is a VZCustomVirtioDevice, unsaveable (ADR 0059 D1)" >&2
        exit 2
    fi
    cfound=0
    for ct in "${VGATE_CKPT_TAGS[@]}"; do [ "$ct" = "$fck" ] && cfound=1; done
    [ "$cfound" = 1 ] || { echo "vgate: ${VGATE_RUN_TAGS[$i]} --from-checkpoint $fck: no 'vgate_checkpoint $fck' declared" >&2; exit 2; }
    # D7(c): a warm leg cannot carry a host client — listener/relay/client
    # state lives outside the bundle.
    for ct in "${VGATE_CLIENT_TAGS[@]}"; do
        [ "$ct" = "${VGATE_RUN_TAGS[$i]}" ] && { echo "vgate: vgate_client $ct on a --from-checkpoint leg — host client state is outside the checkpoint bundle (ADR 0059 D7(c))" >&2; exit 2; }
    done
done

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }
GATE_LOG="$(art "$VGATE_NAME-gate.txt")"
REPORT="$(art "$VGATE_NAME-report.txt")"
exec > >(tee "$GATE_LOG") 2>&1
# The false-PASS guard, stage 2 (issue #1338): the same completion check as
# above, plus the evidence teardown that needs a run dir to exist. THIS trap
# replaces the stage-1 one, so from here on a premature exit also cleans up.
trap 'gate_end 2>/dev/null || true; sleep 0.5; if [ "${VGATE_COMPLETED:-0}" != 1 ]; then echo "vgate: harness exited before its result block -- FAIL (see issue #1338)" >&2; exit 2; fi' EXIT

REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "=== vgate $VGATE_NAME: $VGATE_DESC ==="
echo "spec: $SPEC"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- guest ELF freshness (issue #1503) ---------------------------------------
# Exists-only copy of .build/go/GOSH.ELF (and GOSSHD.ELF, PR #1508) boots
# whatever this worktree last built by hand. Fail closed HERE -- before
# zig build / VM boot -- so a foreign binary is a named ensure-guest-elf
# error rather than a behavioral red or a false green. fleet.sh `ensure`s
# once per invocation (hash-cached); this check is then a cache hit.
while IFS= read -r _guest_elf_app; do
    [ -n "$_guest_elf_app" ] || continue
    if ! bash "$ROOT/tools/go/ensure-guest-elf.sh" check "$_guest_elf_app"; then
        echo "vgate: refusing to boot a stale or missing ${_guest_elf_app}.ELF (issue #1503)" >&2
        VGATE_COMPLETED=1
        exit 1
    fi
done < <(bash "$ROOT/tools/go/ensure-guest-elf.sh" needed-by "$SPEC")

# --- one shared build preamble (never per gate) ------------------------------
if [ "${VGATE_NO_BUILD:-0}" = "1" ]; then
    echo "vgate: skipping build preamble (VGATE_NO_BUILD=1)"
else
    # shellcheck disable=SC2086
    gate_fmt_check $VGATE_FMT
    zig build
    zig build image
    # shellcheck disable=SC2086
    gate_build_runner $VGATE_RUNNER_FLAGS
fi

# --- preflight: name the two failures that otherwise surface at VM boot -----
# Runs for BOTH branches above: the build path just signed the binary, but
# VGATE_NO_BUILD=1 skips the build entirely, so a stale or hand-built runner
# reaches the VM without anyone having checked it. Also states the host's
# hypervisor capability, so "this machine cannot boot a guest" is said out
# loud instead of being blamed on the gate under test.
gate_preflight_vz

gate_begin "$VGATE_NAME"
case "$VGATE_SHARE" in
    arm) gate_arm_share ;;
    seed) gate_seed_share ;;
    arm-virtiofs) gate_arm_virtiofs_share ;;
    seed-virtiofs) gate_seed_virtiofs_share ;;
esac
echo "run dir: $RUN_DIR"

# --- setup: files + setup-python hooks, in declaration order -----------------
for i in "${!VGATE_FILE_NAMES[@]}"; do
    printf '%s' "${VGATE_FILE_BODIES[$i]}" > "$RUN_DIR/${VGATE_FILE_NAMES[$i]}"
done
for i in "${!VGATE_SETUP_PY[@]}"; do
    printf '%s' "${VGATE_SETUP_PY[$i]}" > "$RUN_DIR/setup-$i.py"
    RUN_DIR="$RUN_DIR" python3 "$RUN_DIR/setup-$i.py"
done

: > "$REPORT"
{
    echo "VIRELAIOS vgate $VGATE_NAME -- $VGATE_DESC"
    echo "spec: $SPEC"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    for n in "${VGATE_NOTES[@]}"; do echo "note: $n"; done
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

# --- assert engine ------------------------------------------------------------
VG_SER="" VG_TAG="" VG_OUT="" VG_KEEP_FILES=()
vg_note_evidence() { VG_KEEP_FILES+=("$1"); }

# The armed share is a per-run temp dir deleted at gate_end, so an assert that
# reads it must lift the file it compared into RUN_DIR first or the evidence is
# gone by the time anyone looks. Flattens the RELPATH into the RUN_DIR name
# (`share-SELFTEST_REPORT.txt`) so the teardown's `artifacts/NAME-$f` is unique
# and readable; echoes the RUN_DIR-relative name it registered (empty when the
# share file is not there — the assert has already failed by then).
vg_share_evidence() {
    local rel="$1" dst
    [ -n "${SHARE:-}" ] && [ -f "$SHARE/$rel" ] || return 0
    dst="share-$(printf '%s' "$rel" | tr '/ ' '__')"
    cp -f "$SHARE/$rel" "$RUN_DIR/$dst" 2>/dev/null || return 0
    vg_note_evidence "$dst"
    printf '%s' "$dst"
}

vg_assert_one() {
    # $1=kind $2=a1 $3=a2 $4=body -> returns 0 on hold, prints one detail line
    local kind="$1" a1="$2" a2="$3" body="$4" ok=0 detail=""
    case "$kind" in
        serial-contains)
            grep -a -qF -- "$a1" "$VG_SER" 2>/dev/null && ok=1
            detail="serial-contains [$a1]=$ok" ;;
        serial-contains-file)
            if [ -f "$RUN_DIR/$a1" ]; then
                grep -a -qF -- "$(cat "$RUN_DIR/$a1")" "$VG_SER" 2>/dev/null && ok=1
            fi
            detail="serial-contains-file [$a1]=$ok" ;;
        serial-count)
            local n; n="$(grep -a -cF -- "$a1" "$VG_SER" 2>/dev/null || true)"
            [ -n "$n" ] || n=0
            [ "$n" -ge "$a2" ] && ok=1
            detail="serial-count [$a1]=$n (min $a2) ok=$ok" ;;
        serial-exact)
            # Whole-line match, mirroring grep -aFxc in the legacy scripts:
            # a command echo (prompt prefix) and its output are different
            # lines, so substring counting would double-count typed markers.
            local n; n="$(grep -a -cFx -- "$a1" "$VG_SER" 2>/dev/null || true)"
            [ -n "$n" ] || n=0
            [ "$n" = "$a2" ] && ok=1
            detail="serial-exact [$a1]=$n (want $a2) ok=$ok" ;;
        serial-absent)
            grep -a -qF -- "$a1" "$VG_SER" 2>/dev/null || ok=1
            detail="serial-absent [$a1] ok=$ok" ;;
        serial-echo)
            gate_serial_has_echo "$VG_SER" "$a1" && ok=1
            detail="serial-echo [$a1]=$ok" ;;
        output-contains)
            grep -a -qF -- "$a1" "$VG_OUT" 2>/dev/null && ok=1
            detail="output-contains [$a1]=$ok" ;;
        client-contains)
            local cap="$RUN_DIR/client-$VG_TAG.out"
            vg_note_evidence "client-$VG_TAG.out"
            grep -a -qF -- "$a1" "$cap" 2>/dev/null && ok=1
            detail="client-contains [$a1]=$ok" ;;
        capture-equals)
            local cap="$RUN_DIR/$a1" fix="$RUN_DIR/$a2" tries=0
            vg_note_evidence "$a1"
            while [ "$tries" -lt 5 ]; do
                if [ -f "$cap" ] && [ -f "$fix" ] && cmp -s "$cap" "$fix"; then ok=1; break; fi
                tries=$((tries+1)); sleep 0.5
            done
            detail="capture-equals [$a1]==[$a2]=$ok" ;;
        capture-empty)
            vg_note_evidence "$a1"
            { [ ! -f "$RUN_DIR/$a1" ] || [ ! -s "$RUN_DIR/$a1" ]; } && ok=1
            detail="capture-empty [$a1]=$ok" ;;
        share-equals)
            # $a1 is a path relative to the ARMED share; $a2 is the expectation
            # — either the name of a $RUN_DIR fixture (a vgate_file, per the
            # FILE/FIXTURE convention the capture kinds already use) or a
            # literal. A value that names an EXISTING RUN_DIR file is taken as
            # the fixture, so the fixture form wins on a collision — and a
            # typo'd fixture name falls through to a literal compare, which
            # still FAILS rather than passing: the default is never `ok`.
            # 5x0.5 s retry like capture-equals: the guest's last write can
            # land just after the VM stops on --script-expect.
            local want="$RUN_DIR/$a2" form="fixture" tries=0
            if [ ! -f "$want" ]; then
                printf '%s' "$a2" > "$RUN_DIR/share-literal"
                want="$RUN_DIR/share-literal"; form="literal"
            fi
            if [ -z "${SHARE:-}" ]; then
                detail="share-equals [$a1] FAIL (no armed share -- declare vgate_share arm|seed)"
            else
                while [ "$tries" -lt 5 ]; do
                    if [ -f "$SHARE/$a1" ] && cmp -s "$SHARE/$a1" "$want"; then ok=1; break; fi
                    tries=$((tries+1)); sleep 0.5
                done
                vg_share_evidence "$a1" >/dev/null
                detail="share-equals [$a1]==${form}[${a2}]=$ok"
                if [ "$ok" = 0 ]; then
                    if [ -f "$SHARE/$a1" ]; then detail="$detail (differs)"
                    else detail="$detail (missing on the share)"; fi
                fi
            fi ;;
        share-contains)
            # $a1 relative to the armed share, $a2 a fixed string it must
            # contain (same fail-closed shape as share-equals: a missing file
            # is a FAIL, never a skip).
            if [ -z "${SHARE:-}" ]; then
                detail="share-contains [$a1] FAIL (no armed share -- declare vgate_share arm|seed)"
            else
                grep -a -qF -- "$a2" "$SHARE/$a1" 2>/dev/null && ok=1
                vg_share_evidence "$a1" >/dev/null
                detail="share-contains [$a1][$a2]=$ok"
                [ "$ok" = 1 ] || detail="$detail (missing or does not contain it)"
            fi ;;
        snapshot)
            local snap; snap="$(ls -t "$RUN_DIR"/$a1 2>/dev/null | head -1 || true)"
            if [ -n "$snap" ] && [ -f "$snap" ]; then
                vg_note_evidence "$(basename "$snap")"
                printf '%s' "$body" > "$RUN_DIR/snap-check.py"
                if python3 - "$snap" < "$RUN_DIR/snap-check.py" > "$RUN_DIR/snap-check.out" 2>&1; then
                    ok=1; detail="snapshot [$a1] PASS ($(basename "$snap"))"
                else
                    detail="snapshot [$a1] FAIL ($(basename "$snap"); see $VGATE_NAME run $VG_TAG)"
                    tail -5 "$RUN_DIR/snap-check.out" || true
                fi
                cat "$RUN_DIR/snap-check.out" || true
            else
                detail="snapshot [$a1] FAIL (no file)"
            fi ;;
        python)
            printf '%s' "$body" > "$RUN_DIR/check-$VG_TAG.py"
            if RUN_DIR="$RUN_DIR" VG_SER="$VG_SER" VG_TAG="$VG_TAG" VG_SHARE="$SHARE" \
                    python3 "$RUN_DIR/check-$VG_TAG.py" > "$RUN_DIR/check-$VG_TAG.out" 2>&1; then
                ok=1; detail="python [$VG_TAG] PASS"
            else
                detail="python [$VG_TAG] FAIL"; tail -5 "$RUN_DIR/check-$VG_TAG.out" || true
            fi
            cat "$RUN_DIR/check-$VG_TAG.out" || true ;;
        *) detail="UNKNOWN-ASSERT [$kind]"; ok=0 ;;
    esac
    echo "  $detail"
    echo "  $detail" >> "$REPORT"
    [ "$ok" = 1 ]
}

# --- run driver ---------------------------------------------------------------
REPEAT="$VGATE_REPEAT"
if [ -n "$VGATE_REPEAT_ENV" ] && [ -n "${!VGATE_REPEAT_ENV:-}" ] 2>/dev/null; then
    REPEAT="${!VGATE_REPEAT_ENV}"
fi

# --- warm checkpoint base boots (ADR 0059 D4/D9) -----------------------------
# One base boot per spec invocation, ahead of every leg: cold boot → settle
# marker → a fresh `virelai> ` prompt → pause/save/stop. The bundle under
# $RUN_DIR/ckpt-<tag>/ is immutable once taken; each warm leg gets its own
# clones (D3). VGATE_WARM=off skips base boots entirely — every
# --from-checkpoint leg then runs cold with its checkpoint's flags and its
# ORIGINAL script flags, and the receipt records warm=cold.
PASS=0 TOTAL=0 n=0
VGATE_WARM="${VGATE_WARM:-on}"
CKPT_OK=" "
if [ "$VGATE_WARM" != "off" ]; then
for ci in "${!VGATE_CKPT_TAGS[@]}"; do
    ctag="${VGATE_CKPT_TAGS[$ci]}"
    settle="${VGATE_CKPT_SETTLE[$ci]}"
    ckdir="$RUN_DIR/ckpt-$ctag"
    mkdir -p "$ckdir"
    TOTAL=$((TOTAL + 1))
    echo; echo "=== $VGATE_NAME checkpoint $ctag ==="
    # Same per-boot convention as a leg: the runner creates a fresh EFI store
    # (gate_begin's placeholder is empty); the store this boot writes is the
    # checkpoint epoch's, pinned into the bundle afterwards (D3).
    rm -f "$RUN_DIR/vm-serial-ckpt-$ctag.log" "$RUN_DIR/efi-vars.bin"
    eval "set -- ${VGATE_CKPT_FLAGS[$ci]}"
    ckexp=()
    for f in "$@"; do
        f="${f//\$RUN_DIR/$RUN_DIR}"
        f="${f//\$\{RUN_DIR\}/$RUN_DIR}"
        ckexp+=("$f")
    done
    set +e
    "$VZ_RUNNER_BIN" "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-ckpt-$ctag.log" \
        --vz-restore --vz-restore-save "$ckdir" --vz-restore-settle "$settle" \
        --timeout 300 "${ckexp[@]}" > "$RUN_DIR/run-ckpt-$ctag.out" 2>&1
    CRC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-ckpt-$ctag.log" ] && cp "$RUN_DIR/vm-serial-ckpt-$ctag.log" "$(art "$VGATE_NAME-ckpt-$ctag-serial.log")" || true
    cp "$RUN_DIR/run-ckpt-$ctag.out" "$(art "$VGATE_NAME-ckpt-$ctag-run.txt")"
    if [ "$CRC" = 0 ] && [ -f "$ckdir/state.vzsave" ] && [ -f "$ckdir/overlay.asif" ] && [ -f "$ckdir/machine-id.bin" ]; then
        # Pinned store for the bundle (D3); a real boot always leaves it,
        # a stub runner doesn't — the bundle member exists either way.
        cp "$RUN_DIR/efi-vars.bin" "$ckdir/efi-vars.bin" 2>/dev/null || : > "$ckdir/efi-vars.bin"
        if [ -n "${SHARE:-}" ]; then
            cp -cR "$SHARE" "$ckdir/share" 2>/dev/null || cp -R "$SHARE" "$ckdir/share"
        fi
        CKPT_OK="$CKPT_OK$ctag "
        echo "ckpt-$ctag: PASS (bundle: state.vzsave+overlay.asif+efi-vars.bin+machine-id.bin$([ -d "$ckdir/share" ] && printf '+share/'))" | tee -a "$REPORT"
        PASS=$((PASS + 1))
    else
        echo "ckpt-$ctag: FAIL (runner rc=$CRC — no checkpoint bundle; warm legs on '$ctag' will not attempt)" | tee -a "$REPORT"
    fi
done
fi
ARMED_SHARE="${SHARE:-}"

while [ "$n" -lt "$REPEAT" ]; do
    n=$((n + 1))
    for i in "${!VGATE_RUN_TAGS[@]}"; do
        base="${VGATE_RUN_TAGS[$i]}"
        from_ckpt="${VGATE_RUN_FROM_CKPT[$i]}"
        strict="${VGATE_RUN_STRICT[$i]}"
        corrupt="${VGATE_RUN_CORRUPT[$i]}"
        if [ "$REPEAT" -gt 1 ]; then tag="${base}-$(printf '%02d' "$n")"; else tag="$base"; fi
        client_pid=""
        TOTAL=$((TOTAL + 1))
        echo; echo "=== $VGATE_NAME run $tag ==="
        SHARE="$ARMED_SHARE"
        rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
        # A warm leg's share is its own checkpoint clone — the bundle's
        # WINDOWS.SAV is authoritative, so the per-leg reset only applies to
        # genuinely cold boots of the armed share.
        if [ -n "${SHARE:-}" ] && { [ -z "$from_ckpt" ] || [ "$VGATE_WARM" = "off" ]; }; then
            rm -f "$SHARE/WINDOWS.SAV"
        fi
        set +e
        eval "set -- ${VGATE_RUN_FLAGS[$i]}"
        # Specs name $RUN_DIR files in flags; expand the literal token now
        # that RUN_DIR exists (file bodies and asserts stay literal).
        expanded=()
        for f in "$@"; do
            f="${f//\$RUN_DIR/$RUN_DIR}"
            f="${f//\$\{RUN_DIR\}/$RUN_DIR}"
            expanded+=("$f")
        done
        set -- "${expanded[@]}"
        runner_args=("$@")
        # ADR 0059 D2: a warm leg inherits its checkpoint's device shape —
        # resolve the checkpoint's flag vector now, RUN_DIR-expanded like
        # the leg's own.
        ckpt_args=() ckdir="" legdir=""
        if [ -n "$from_ckpt" ]; then
            ckdir="$RUN_DIR/ckpt-$from_ckpt"
            legdir="$RUN_DIR/warm-$tag"
            cki=-1
            for _ci in "${!VGATE_CKPT_TAGS[@]}"; do
                [ "${VGATE_CKPT_TAGS[$_ci]}" = "$from_ckpt" ] && cki="$_ci"
            done
            eval "set -- ${VGATE_CKPT_FLAGS[$cki]}"
            ckexp=()
            for f in "$@"; do
                f="${f//\$RUN_DIR/$RUN_DIR}"
                f="${f//\$\{RUN_DIR\}/$RUN_DIR}"
                ckexp+=("$f")
            done
            ckpt_args=("${ckexp[@]}")
            set -- "${runner_args[@]}"
        fi
        # M46 RC2 (#1069): launch the declared during-run TCP client(s) in the
        # background BEFORE the VM, so the hook can connect while it boots.
        # The client's positional args are isolated (runner_args preserves the
        # VMRunner flags; `$@` is reused inside the loop).
        for ci in "${!VGATE_CLIENT_TAGS[@]}"; do
            [ "${VGATE_CLIENT_TAGS[$ci]}" = "$base" ] || continue
            eval "set -- ${VGATE_CLIENT_ARGS[$ci]}"
            cexpanded=()
            for f in "$@"; do
                f="${f//\$RUN_DIR/$RUN_DIR}"
                f="${f//\$\{RUN_DIR\}/$RUN_DIR}"
                cexpanded+=("$f")
            done
            set -- "${cexpanded[@]}"
            RUN_DIR="$RUN_DIR" VG_TAG="$tag" VG_SER="$RUN_DIR/vm-serial-$tag.log" \
                python3 tools/lib/vgate-client.py "$@" > "$RUN_DIR/client-$tag.log" 2>&1 &
            client_pid=$!
        done
        set -- "${runner_args[@]}"
        warm_field="cold"
        if [ -n "$from_ckpt" ] && [ "$VGATE_WARM" = "off" ]; then
            # VGATE_WARM=off (M131c/d parity knob): cold boot with the
            # checkpoint's device flags + the leg's ORIGINAL script flags
            # (the first --script-after waits on the real boot marker).
            # A strict leg can never restore under this knob — FAIL it.
            if [ "$strict" = 1 ]; then
                echo "$tag: warm-strict under VGATE_WARM=off — nothing can restore" >> "$RUN_DIR/run-$tag.out"
                RC=99
            else
                "$VZ_RUNNER_BIN" "${GATE_RUNNER_ARGS[@]}" \
                    --serial "$RUN_DIR/vm-serial-$tag.log" \
                    "${ckpt_args[@]}" "${runner_args[@]}" > "$RUN_DIR/run-$tag.out" 2>&1
                RC=$?
            fi
        elif [ -n "$from_ckpt" ]; then
            case "$CKPT_OK" in *" $from_ckpt "*) leg_blocked="" ;; *) leg_blocked=1 ;; esac
            if [ -n "$leg_blocked" ]; then
                RC=99
                echo "$tag: no warm attempt — checkpoint ckpt-$from_ckpt failed earlier" >> "$RUN_DIR/run-$tag.out"
                echo "$tag: FAIL — checkpoint ckpt-$from_ckpt failed; no warm attempt and no cold substitute (ADR 0059 D4)" | tee -a "$REPORT"
                warm_field=""
            else
                # ADR 0059 D3: the leg's writable world is a fresh clone of
                # the bundle — overlay, vars, state, machine-id, and the
                # share when armed; the bundle itself is never touched.
                mkdir -p "$legdir"
                cp -c "$ckdir/state.vzsave" "$legdir/state.vzsave" 2>/dev/null || cp "$ckdir/state.vzsave" "$legdir/state.vzsave"
                cp -c "$ckdir/overlay.asif" "$legdir/overlay.asif" 2>/dev/null || cp "$ckdir/overlay.asif" "$legdir/overlay.asif"
                cp -c "$ckdir/efi-vars.bin" "$legdir/efi-vars.bin" 2>/dev/null || cp "$ckdir/efi-vars.bin" "$legdir/efi-vars.bin"
                cp "$ckdir/machine-id.bin" "$legdir/machine-id.bin"
                if [ -d "$ckdir/share" ]; then
                    cp -cR "$ckdir/share" "$legdir/share" 2>/dev/null || cp -R "$ckdir/share" "$legdir/share"
                    SHARE="$legdir/share"   # share-* / python asserts see the leg's own writes (D3)
                fi
                if [ "$corrupt" = "truncate-state" ]; then
                    python3 -c 'import os,sys; p=sys.argv[1]; os.truncate(p, max(1, os.path.getsize(p)//2))' "$legdir/state.vzsave"
                fi
                # Harness-owned members retarget the leg's clones.
                warm_args=()
                j=0
                while [ "$j" -lt "${#GATE_RUNNER_ARGS[@]}" ]; do
                    ga="${GATE_RUNNER_ARGS[$j]}"
                    case "$ga" in
                        --vars) warm_args+=(--vars "$legdir/efi-vars.bin"); j=$((j+2)) ;;
                        --virtio-fs) warm_args+=(--virtio-fs "$legdir/share"); j=$((j+2)) ;;
                        *) warm_args+=("$ga"); j=$((j+1)) ;;
                    esac
                done
                "$VZ_RUNNER_BIN" "${warm_args[@]}" \
                    --serial "$RUN_DIR/vm-serial-$tag.log" \
                    "${ckpt_args[@]}" --vz-restore --vz-restore-load "$legdir" \
                    "${runner_args[@]}" > "$RUN_DIR/run-$tag-warm.out" 2>&1
                RC=$?
                if [ "$RC" = 75 ]; then
                    # The dedicated refusal status (vzRestoreRefusedStatus):
                    # exactly one stdout line names the VZErrorDomain code —
                    # fallback fires ONLY on this signal, never on an assert
                    # failure (ADR 0059 D8).
                    rcode="$(sed -n 's/.*VZ-RESTORE: refused code=\([0-9][0-9]*\).*/\1/p' "$RUN_DIR/run-$tag-warm.out" | head -1)"
                    if [ "$strict" = 1 ]; then
                        warm_field="refused(${rcode:-?})"
                        cp "$RUN_DIR/run-$tag-warm.out" "$RUN_DIR/run-$tag.out"
                        echo "$tag: warm restore REFUSED code=${rcode:-?} — strict leg FAILs (ADR 0059 D8; no cold substitute)" | tee -a "$REPORT"
                    else
                        warm_field="fallback(${rcode:-?})"
                        echo "$tag: warm restore REFUSED code=${rcode:-?} — degrading to a single cold boot (ADR 0059 D8; no retry)" | tee -a "$REPORT"
                        rm -f "$RUN_DIR/vm-serial-$tag.log"
                        "$VZ_RUNNER_BIN" "${warm_args[@]}" \
                            --serial "$RUN_DIR/vm-serial-$tag.log" \
                            "${ckpt_args[@]}" "${runner_args[@]}" > "$RUN_DIR/run-$tag.out" 2>&1
                        RC=$?
                    fi
                else
                    warm_field="restored"
                    cp "$RUN_DIR/run-$tag-warm.out" "$RUN_DIR/run-$tag.out"
                fi
            fi
        else
            "$VZ_RUNNER_BIN" "${GATE_RUNNER_ARGS[@]}" \
                --serial "$RUN_DIR/vm-serial-$tag.log" "${runner_args[@]}" > "$RUN_DIR/run-$tag.out" 2>&1
            RC=$?
        fi
        set -e
        [ -f "$RUN_DIR/run-$tag-warm.out" ] && cp "$RUN_DIR/run-$tag-warm.out" "$(art "$VGATE_NAME-run-$tag-warm.txt")" || true
        VG_TAG="$tag" VG_SER="$RUN_DIR/vm-serial-$tag.log" VG_OUT="$RUN_DIR/run-$tag.out"
        [ -f "$VG_SER" ] && cp "$VG_SER" "$(art "$VGATE_NAME-serial-$tag.log")" || true
        cp "$VG_OUT" "$(art "$VGATE_NAME-run-$tag.txt")"
        run_ok=1
        if [ -n "$client_pid" ]; then
            set +e; wait "$client_pid"; client_rc=$?; set -e
            echo "$tag: client-rc=$client_rc" | tee -a "$REPORT"
            [ "$client_rc" = 0 ] || run_ok=0
            [ -f "$RUN_DIR/client-$tag.out" ] && cp "$RUN_DIR/client-$tag.out" "$(art "$VGATE_NAME-client-$tag.out")" || true
            [ -f "$RUN_DIR/client-$tag.log" ] && cp "$RUN_DIR/client-$tag.log" "$(art "$VGATE_NAME-client-$tag.log")" || true
        fi
        allowed_rc="0"
        for arc in "${VGATE_ALLOW_RC[@]}"; do
            [ "${arc%%$'\x1f'*}" = "$base" ] && allowed_rc="${arc#*$'\x1f'}"
        done
        rc_matched=0
        for code in $allowed_rc; do
            [ "$RC" = "$code" ] && { rc_matched=1; break; }
        done
        [ "$rc_matched" = 1 ] || { run_ok=0; echo "  runner-rc $RC not in allowed set ($allowed_rc)" | tee -a "$REPORT"; }
        echo "$tag: runner-rc=$RC" | tee -a "$REPORT"
        for a in "${VGATE_ASSERTS[@]}"; do
            atag="${a%%$'\x1f'*}"; rest="${a#*$'\x1f'}"
            [ "$atag" = "$base" ] || continue
            akind="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
            aa1="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
            aa2="${rest%%$'\x1f'*}"; abody="${rest#*$'\x1f'}"
            vg_assert_one "$akind" "$aa1" "$aa2" "$abody" || run_ok=0
        done
        echo "$tag: $([ "$run_ok" = 1 ] && echo PASS || echo FAIL)${warm_field:+ warm=$warm_field}" | tee -a "$REPORT"
        [ "$run_ok" = 1 ] && PASS=$((PASS + 1))
    done
done

for f in "${VG_KEEP_FILES[@]}"; do
    [ -f "$RUN_DIR/$f" ] && cp "$RUN_DIR/$f" "$(art "$VGATE_NAME-$f")" || true
done

# Past this point the harness has done its job: every planned run booted and
# every assert was evaluated, so the trap must let this rc through untouched.
VGATE_COMPLETED=1

echo; echo "=== result ==="
if [ "$PASS" = "$TOTAL" ]; then
    echo "vgate $VGATE_NAME: PASS ($PASS/$TOTAL runs)"
    echo "PASS: $PASS/$TOTAL" >> "$REPORT"
    exit 0
fi
echo "vgate $VGATE_NAME: FAILED ($PASS/$TOTAL runs; see $REPORT)"
echo "FAIL: $PASS/$TOTAL" >> "$REPORT"
exit 1
