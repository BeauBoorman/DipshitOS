#!/usr/bin/env bash
#
# test-gate-run.sh -- class-A self-test for the VZ preflight in
# tools/lib/gate-run.sh (claim #1259) and for the false-PASS guard in
# tools/gate/vgate.sh (issue #1338).
#
# Why this exists: the preflight's whole job is to FAIL LOUDLY in two cases
# that used to surface at VM boot as something else. A checker whose negative
# path is never exercised is the same class of bug it was written to catch --
# it can be wired backwards, or stop matching, and still report green. So the
# negative paths are asserted here, on a CI runner, with no VM anywhere.
#
# Same reasoning, one level up, for the harness itself (issue #1338): a run
# that ends before its result block must never read as PASS, and the shells
# where that is possible (bash < 4.4 exits ZERO on an empty-array expansion
# under `set -u`) must be refused at the door. Both are asserted below.
#
# Hermetic by construction: `codesign` and `sysctl` are stubbed on PATH, so the
# real signature of any binary and the real capability of any host are
# irrelevant to the result. Class A -- runs in CI, needs no Apple silicon.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# gate-run.sh sets -euo pipefail for its callers; every negative case below is
# an EXPECTED non-zero exit, so turn -e back off after sourcing.
# shellcheck source=tools/lib/gate-run.sh
source tools/lib/gate-run.sh
set +e

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/virelai-test-gate-run.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- stubs ------------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

# codesign stub: prints $STUB_CODESIGN_OUT and exits $STUB_CODESIGN_RC.
cat > "$STUB_BIN/codesign" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${STUB_CODESIGN_OUT:-}"
exit "${STUB_CODESIGN_RC:-0}"
SH

# sysctl stub: answers the two keys the preflight reads.
# NOTE ${VAR-default}, not ${VAR:-default}: an explicitly empty value must
# stay empty, or the "capability unreadable" case cannot be expressed.
cat > "$STUB_BIN/sysctl" <<'SH'
#!/usr/bin/env bash
# usage: sysctl -n <key>
# STUB_SYSCTL_RC simulates an absent key / non-Darwin (sysctl exits non-zero).
[ -z "${STUB_SYSCTL_RC:-}" ] || exit "$STUB_SYSCTL_RC"
case "${2:-}" in
    kern.hv_support)     printf '%s\n' "${STUB_HV_SUPPORT-1}" ;;
    kern.hv_vmm_present) printf '%s\n' "${STUB_HV_VMM_PRESENT-0}" ;;
    *) exit 1 ;;
esac
SH
# hv probe stub: fakes the one machine-readable line hv-probe.c prints, so the
# code->verdict mapping is exercised without a hypervisor needing to exist.
cat > "$STUB_BIN/hvprobe-stub" <<'SH'
#!/usr/bin/env bash
printf 'hv_vm_create(NULL) -> %s\n' "${STUB_HV_CODE:-0x00000000}"
printf 'HV_CODE=%s HV_NAME=%s\n' "${STUB_HV_CODE:-0x00000000}" "${STUB_HV_NAME:-HV_SUCCESS}"
SH
chmod +x "$STUB_BIN/codesign" "$STUB_BIN/sysctl" "$STUB_BIN/hvprobe-stub"
ORIG_PATH="$PATH"
PATH="$STUB_BIN:$PATH"

STUB_PROBE="$STUB_BIN/hvprobe-stub"
NO_PROBE="$TMP/no-such-hv-probe"

# --- fixtures ---------------------------------------------------------------
BIN="$TMP/VMRunner"
: > "$BIN"                                   # any file; the stub answers
MISSING="$TMP/definitely-not-built"

ENTITLED_OUT="Executable=$BIN
[Dict]
	[Key] com.apple.security.virtualization
	[Value]
		[Bool] true"
BARE_OUT="code object is not signed at all
In subcomponent: $BIN"

CASE_OUT=""
run() { CASE_OUT="$("$@" 2>&1)"; return $?; }

echo "=== test-gate-run: the VZ preflight fails loudly, and passes when it should ==="

# --- gate_assert_runner_entitled --------------------------------------------
echo
echo "── gate_assert_runner_entitled ──"

STUB_CODESIGN_OUT="$ENTITLED_OUT" STUB_CODESIGN_RC=0
export STUB_CODESIGN_OUT STUB_CODESIGN_RC
run gate_assert_runner_entitled "$BIN"; rc=$?
[ "$rc" = 0 ] && ok "entitled binary passes (rc=0)" \
              || bad "entitled binary should pass, got rc=$rc: $CASE_OUT"

STUB_CODESIGN_OUT="$BARE_OUT" STUB_CODESIGN_RC=1
export STUB_CODESIGN_OUT STUB_CODESIGN_RC
run gate_assert_runner_entitled "$BIN"; rc=$?
if [ "$rc" = 0 ]; then
    bad "UN-ENTITLED binary must fail, got rc=0"
else
    ok "un-entitled binary fails (rc=$rc)"
fi
case "$CASE_OUT" in
    *"$VZ_RUNNER_ENTITLEMENT"*) ok "the failure names the missing entitlement" ;;
    *) bad "the failure should name $VZ_RUNNER_ENTITLEMENT: $CASE_OUT" ;;
esac
case "$CASE_OUT" in
    *"--entitlements host/vm-runner/entitlements.plist"*) ok "the failure names the codesign fix" ;;
    *) bad "the failure should name the codesign command: $CASE_OUT" ;;
esac
case "$CASE_OUT" in
    *"swift build"*) ok "the failure names the bare-swift-build cause" ;;
    *) bad "the failure should mention the bare 'swift build' cause: $CASE_OUT" ;;
esac

run gate_assert_runner_entitled "$MISSING"; rc=$?
[ "$rc" != 0 ] && ok "a missing runner binary fails (rc=$rc)" \
               || bad "a missing runner binary must fail"

# Default argument must be the real runner path, not something else.
[ "$VZ_RUNNER_BIN" = "host/vm-runner/.build/release/VMRunner" ] \
    && ok "VZ_RUNNER_BIN is the release VMRunner path" \
    || bad "VZ_RUNNER_BIN is '$VZ_RUNNER_BIN'"

# --- gate_report_hv_capability ----------------------------------------------echo
echo "── gate_report_hv_capability (real probe shapes) ──"

export VZ_HV_PROBE_BIN="$STUB_PROBE"
STUB_HV_SUPPORT=1 STUB_HV_VMM_PRESENT=0
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT

# The reference host: hypervisor created.
STUB_HV_NAME=HV_SUCCESS STUB_HV_CODE=0x00000000
export STUB_HV_NAME STUB_HV_CODE
run gate_report_hv_capability; rc=$?
[ "$rc" = 0 ] && ok "HV_SUCCESS passes (rc=0)" || bad "HV_SUCCESS should pass, got rc=$rc: $CASE_OUT"
case "$CASE_OUT" in
    *"hv_vm_create -> 0x00000000 (HV_SUCCESS)"*) ok "the verdict line reports the actual call and code" ;;
    *) bad "the verdict line should report the hv call: $CASE_OUT" ;;
esac

# The hosted-runner case: the real refusal.
STUB_HV_NAME=HV_UNSUPPORTED STUB_HV_CODE=0xfae9400f
STUB_HV_VMM_PRESENT=1
export STUB_HV_NAME STUB_HV_CODE STUB_HV_VMM_PRESENT
run gate_report_hv_capability; rc=$?
if [ "$rc" = 0 ]; then
    bad "HV_UNSUPPORTED must fail, got rc=0"
else
    ok "HV_UNSUPPORTED fails (rc=$rc)"
fi
case "$CASE_OUT" in
    *"0xfae9400f HV_UNSUPPORTED"*) ok "it quotes the code and its name" ;;
    *) bad "it should quote the refused code: $CASE_OUT" ;;
esac
case "$CASE_OUT" in
    *"itself a VM"*) ok "it names the nested-virtualization case" ;;
    *) bad "it should identify the host-is-a-guest case: $CASE_OUT" ;;
esac
case "$CASE_OUT" in
    *"regardless of the code under test"*) ok "it says the gate is not at fault" ;;
    *) bad "it should say the failure is not the gate's: $CASE_OUT" ;;
esac

# The trap: a mis-signed probe must NEVER be reported as a host verdict.
STUB_HV_NAME=HV_DENIED STUB_HV_CODE=0xfae94007
export STUB_HV_NAME STUB_HV_CODE
run gate_report_hv_capability; rc=$?
[ "$rc" != 0 ] && ok "HV_DENIED fails (rc=$rc)" || bad "HV_DENIED must not pass"
case "$CASE_OUT" in
    *"SIGNATURE, not about this"*) ok "it calls HV_DENIED a signature statement" ;;
    *) bad "HV_DENIED must be attributed to the signature, not the host: $CASE_OUT" ;;
esac
case "$CASE_OUT" in
    *"harness fault"*) ok "it says there is no capability verdict here" ;;
    *) bad "HV_DENIED should be a harness fault: $CASE_OUT" ;;
esac
# It must not borrow the phrasing of the host verdict. (A substring check on
# "cannot boot a guest" would fire on the denial message's own warning against
# that reading, so assert on the host-verdict SENTENCE instead.)
case "$CASE_OUT" in
    *"the host refused a hypervisor"*) bad "HV_DENIED must NOT be reported as the host refusing" ;;
    *) ok "it does NOT claim the host refused a hypervisor" ;;
esac

# An unrecognised code is a failure, never a pass.
STUB_HV_NAME=HV_UNKNOWN STUB_HV_CODE=0xdeadbeef
export STUB_HV_NAME STUB_HV_CODE
run gate_report_hv_capability; rc=$?
[ "$rc" != 0 ] && ok "an unrecognised code fails (rc=$rc)" || bad "an unrecognised code must not pass"

# --- fallback: no probe, so the kernel's weaker answer is used, and said so --
echo
echo "── fallback when the probe cannot be built ──"

VZ_HV_PROBE_BIN="$NO_PROBE" VZ_HV_PROBE_SRC="$TMP/no-such-source.c"
export VZ_HV_PROBE_BIN VZ_HV_PROBE_SRC
STUB_HV_SUPPORT=1 STUB_HV_VMM_PRESENT=0
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT
unset STUB_HV_NAME STUB_HV_CODE
run gate_report_hv_capability; rc=$?
[ "$rc" = 0 ] && ok "no probe + hv_support=1 passes via the fallback" \
              || bad "the fallback should pass on hv_support=1, got rc=$rc: $CASE_OUT"
case "$CASE_OUT" in
    *"falling back to the sysctl"*) ok "the fallback is announced, not silent" ;;
    *) bad "the fallback must say it is a fallback: $CASE_OUT" ;;
esac

STUB_HV_SUPPORT=0 STUB_HV_VMM_PRESENT=1
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT
run gate_report_hv_capability; rc=$?
[ "$rc" != 0 ] && ok "no probe + hv_support=0 fails (rc=$rc)" \
               || bad "no probe + hv_support=0 must not pass"

STUB_HV_SUPPORT="" STUB_HV_VMM_PRESENT=""
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT
run gate_report_hv_capability; rc=$?
[ "$rc" != 0 ] && ok "no probe + EMPTY hv_support fails (rc=$rc)" \
               || bad "an empty kern.hv_support must not pass: $CASE_OUT"

STUB_SYSCTL_RC=1
export STUB_SYSCTL_RC
run gate_report_hv_capability; rc=$?
[ "$rc" != 0 ] && ok "no probe + unreadable hv_support fails (rc=$rc)" \
               || bad "an unreadable kern.hv_support must not pass: $CASE_OUT"
unset STUB_SYSCTL_RC

# Back to the stub probe for the preflight section.
VZ_HV_PROBE_SRC="tools/gate/hv-probe.c"
VZ_HV_PROBE_BIN="$STUB_PROBE"
export VZ_HV_PROBE_SRC VZ_HV_PROBE_BIN
STUB_HV_SUPPORT=1 STUB_HV_VMM_PRESENT=0 STUB_HV_NAME=HV_SUCCESS STUB_HV_CODE=0x00000000
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT STUB_HV_NAME STUB_HV_CODE

# --- gate_preflight_vz: both checks, and both must hold ---------------------
echo
echo "── gate_preflight_vz ──"

STUB_HV_SUPPORT=1 STUB_HV_VMM_PRESENT=0 STUB_CODESIGN_OUT="$ENTITLED_OUT" STUB_CODESIGN_RC=0
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT STUB_CODESIGN_OUT STUB_CODESIGN_RC
run gate_preflight_vz "$BIN"; rc=$?
[ "$rc" = 0 ] && ok "capable host + entitled binary passes" \
              || bad "preflight should pass, got rc=$rc: $CASE_OUT"

STUB_CODESIGN_OUT="$BARE_OUT" STUB_CODESIGN_RC=1
export STUB_CODESIGN_OUT STUB_CODESIGN_RC
run gate_preflight_vz "$BIN"; rc=$?
[ "$rc" != 0 ] && ok "capable host + UN-entitled binary fails" \
               || bad "preflight must fail on an un-entitled binary"

STUB_HV_SUPPORT=0 STUB_HV_VMM_PRESENT=1 STUB_CODESIGN_OUT="$ENTITLED_OUT" STUB_CODESIGN_RC=0
STUB_HV_NAME=HV_UNSUPPORTED STUB_HV_CODE=0xfae9400f
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT STUB_CODESIGN_OUT STUB_CODESIGN_RC
run gate_preflight_vz "$BIN"; rc=$?
[ "$rc" != 0 ] && ok "incapable host fails even with an entitled binary" \
               || bad "preflight must fail on an incapable host"
STUB_HV_NAME=HV_SUCCESS STUB_HV_CODE=0x00000000
export STUB_HV_NAME STUB_HV_CODE

# --- wiring invariants ------------------------------------------------------
# The helpers are only worth anything if the gate path actually calls them.
# These are source-level checks on purpose: removing the call is the silent
# regression this preflight exists to prevent.
echo
echo "── wiring ──"

grep -q 'gate_assert_runner_entitled' tools/lib/gate-run.sh \
    && ok "gate-run.sh defines/uses gate_assert_runner_entitled" \
    || bad "gate-run.sh does not reference gate_assert_runner_entitled"

awk '/^gate_build_runner\(\)/,/^}/' tools/lib/gate-run.sh | grep -q 'gate_assert_runner_entitled' \
    && ok "gate_build_runner asserts the entitlement it just applied" \
    || bad "gate_build_runner does not assert the entitlement"

awk '/^gate_preflight_vz\(\)/,/^}/' tools/lib/gate-run.sh | grep -q 'gate_report_hv_capability' \
    && ok "gate_preflight_vz includes the hv capability verdict" \
    || bad "gate_preflight_vz does not check hv capability"

grep -q 'gate_preflight_vz' tools/gate/vgate.sh \
    && ok "vgate.sh runs the preflight in the VZ gate path" \
    || bad "vgate.sh never runs gate_preflight_vz"

# The preflight must run for VGATE_NO_BUILD=1 too -- that is the branch where
# nothing has signed the binary.
awk '/gate_preflight_vz/{print NR}' tools/gate/vgate.sh > "$TMP/preflight.line"
awk '/gate_begin/{print NR; exit}' tools/gate/vgate.sh > "$TMP/begin.line"
if [ -s "$TMP/preflight.line" ] && [ -s "$TMP/begin.line" ] \
        && [ "$(head -1 "$TMP/preflight.line")" -lt "$(head -1 "$TMP/begin.line")" ]; then
    ok "the preflight runs before any VM boot (ahead of gate_begin)"
else
    bad "the preflight must run before gate_begin"
fi

# --- the false-PASS guard (issue #1338) ------------------------------------
# The bug this covers: an empty-array expansion under `set -u` aborted the
# harness with exit status ZERO, and the fleet reported `PASS go-fart (16s)`
# for a gate that never booted a VM, never wrote a serial log and never
# evaluated an assert. Two behaviours have to hold, and neither is observable
# by reading the harness: the floor refuses the shells where that can happen,
# and ANY exit before the result block is non-zero.
echo
echo "── a premature exit is never a PASS (issue #1338) ──"

# The floor at its boundary. The explicit-version form is what makes this
# assertable without a 20-year-old bash on the box. Note that this suite itself
# runs on whatever shell CI used to start it, and on GitHub's macOS runner that
# is /bin/bash 3.2.57 (the job adds nothing to PATH; see the version-aware cases
# below) -- so nothing here may assume a modern RUNNING shell.
for v in 3:2 4:0 4:3 0:0; do
    major="${v%%:*}"; minor="${v##*:}"
    run gate_assert_modern_bash "$major" "$minor"; rc=$?
    [ "$rc" = 2 ] && ok "bash $major.$minor is refused (rc=2)" \
                  || bad "bash $major.$minor must be refused with rc=2, got rc=$rc"
done
case "$CASE_OUT" in
    *env-check.sh*) ok "the refusal names the fix (tools/env-check.sh)" ;;
    *) bad "the refusal should name tools/env-check.sh: $CASE_OUT" ;;
esac
case "$CASE_OUT" in
    *PASS*) ok "the refusal names its failure mode (a false PASS)" ;;
    *) bad "the refusal should say the failure mode is a false PASS: $CASE_OUT" ;;
esac
# The mechanism, not just the verdict: an unbackticked `set -u` here once ate
# its own text (the shell ran it as a command substitution), which is precisely
# the kind of empty output a reader would not notice.
case "$CASE_OUT" in
    *"set -u"*) ok "the refusal names the mechanism (an empty-array expansion under set -u)" ;;
    *) bad "the refusal should explain the mechanism (set -u): $CASE_OUT" ;;
esac

for v in 4:4 5:3 8:0; do
    major="${v%%:*}"; minor="${v##*:}"
    run gate_assert_modern_bash "$major" "$minor"; rc=$?
    [ "$rc" = 0 ] && ok "bash $major.$minor clears the floor" \
                  || bad "bash $major.$minor must clear the floor, got rc=$rc"
done

# ... and the no-arg form judges the shell this suite is running under, which is
# the call the harness itself makes. What that verdict MUST BE is a property of
# the host, so it is computed here rather than assumed: on GitHub's macOS runner
# the suite starts under /bin/bash 3.2.57, where a refusal is the DESIGNED
# outcome. The first draft of this case asserted rc=0 unconditionally and failed
# CI run 35037178834 (2 of 54) -- which is the issue-#1338 lesson one level up:
# a self-test with a host assumption in it reports the host, not the change.
RUN_MAJOR="${BASH_VERSINFO[0]:-0}"; RUN_MINOR="${BASH_VERSINFO[1]:-0}"
if [ "$RUN_MAJOR" -gt 4 ] || { [ "$RUN_MAJOR" -eq 4 ] && [ "$RUN_MINOR" -ge 4 ]; }; then
    RUNNING_MODERN=1
else
    RUNNING_MODERN=0
fi

run gate_assert_modern_bash; rc=$?
if [ "$RUNNING_MODERN" = 1 ]; then
    [ "$rc" = 0 ] && ok "the no-arg form clears the running shell ($BASH_VERSION)" \
                  || bad "the running shell is >= 4.4, so the floor must clear it, not rc=$rc"
else
    [ "$rc" = 2 ] && ok "the no-arg form refuses the running shell ($BASH_VERSION < 4.4)" \
                  || bad "the running shell is < 4.4, so the floor must return rc=2, not rc=$rc"
    case "$CASE_OUT" in
        *env-check.sh*) ok "the running shell's refusal names the fix" ;;
        *) bad "the running shell's refusal should name tools/env-check.sh: $CASE_OUT" ;;
    esac
fi

# End to end, through the real entry point: a spec that exits before the result
# block. Exit status 0 is the dangerous case -- it is exactly what the bash 3.2
# trap produced -- so the guard has to turn ANY premature exit non-zero. The
# scenario needs a shell that clears the floor (the refusal comes first, by
# design), so drive vgate.sh with a modern bash explicitly. Where the host has
# none -- CI's macOS runner ships only /bin/bash 3.2.57 -- say so loudly instead
# of re-measuring the floor and calling it a premature-exit result.
cat > "$TMP/premature.spec" <<'SPEC'
vgate_name vg-premature "self-test fixture: a spec that exits before the result block"
exit 0
SPEC
cat > "$TMP/bogus.spec" <<'SPEC'
vgate_name vg-bogus "self-test fixture: a spec whose DSL call does not exist"
vgate_not_a_real_command
SPEC

MODERN_BASH=""
for cand in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
    [ -n "$cand" ] || continue
    [ -x "$cand" ] || continue
    if "$cand" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }'; then
        MODERN_BASH="$cand"
        break
    fi
done

if [ -n "$MODERN_BASH" ]; then
    VGATE_NO_BUILD=1
    run "$MODERN_BASH" tools/gate/vgate.sh "$TMP/premature.spec"; rc=$?
    [ "$rc" != 0 ] && ok "a spec that exits early is not a PASS (rc=$rc, $MODERN_BASH)" \
                   || bad "a premature exit reported rc=0 -- the false-PASS guard is not wired"
    case "$CASE_OUT" in
        *"exited before its result block"*) ok "the abort names itself as a FAIL" ;;
        *) bad "the abort should say 'exited before its result block': $CASE_OUT" ;;
    esac

    run "$MODERN_BASH" tools/gate/vgate.sh "$TMP/bogus.spec"; rc=$?
    [ "$rc" != 0 ] && ok "a spec with an undefined DSL command is not a PASS (rc=$rc)" \
                   || bad "an undefined DSL command reported rc=0"
    unset VGATE_NO_BUILD
else
    echo "  skip  no bash >= 4.4 anywhere on this host (running: $BASH_VERSION): the"
    echo "  skip  premature-exit scenario sits behind the floor, and the floor is"
    echo "  skip  asserted above; CI's macOS runner has only /bin/bash 3.2.57."
fi

# The refusal must fire in the real entry point, not only in the helper. Only
# assertable where a pre-4.4 bash exists (macOS /bin/bash is 3.2; CI's is not).
OLD_BASH=""
for cand in /bin/bash /usr/bin/bash; do
    [ -x "$cand" ] || continue
    if ! "$cand" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }'; then
        OLD_BASH="$cand"
        break
    fi
done
if [ -n "$OLD_BASH" ]; then
    run "$OLD_BASH" tools/gate/vgate.sh "$TMP/premature.spec"; rc=$?
    [ "$rc" = 2 ] && ok "$OLD_BASH ($("$OLD_BASH" -c 'echo $BASH_VERSION')) refuses the harness (rc=2)" \
                  || bad "$OLD_BASH must refuse the harness with rc=2, got rc=$rc"
    case "$CASE_OUT" in
        *env-check.sh*) ok "the old-bash refusal names the fix" ;;
        *) bad "the old-bash refusal should name tools/env-check.sh: $CASE_OUT" ;;
    esac
else
    echo "  skip  no pre-4.4 bash on this host; the floor was asserted through its boundary cases"
fi

# Wiring: the floor must be called by the harness, before it sources the spec
# (the first thing it would otherwise do with untrusted input)...
grep -q 'gate_assert_modern_bash' tools/gate/vgate.sh \
    && ok "vgate.sh calls the shell floor" \
    || bad "vgate.sh never calls gate_assert_modern_bash"
grep -n 'gate_assert_modern_bash' tools/gate/vgate.sh | head -1 | cut -d: -f1 > "$TMP/floor.line"
grep -n 'source "\$SPEC"' tools/gate/vgate.sh | head -1 | cut -d: -f1 > "$TMP/spec.line"
if [ -s "$TMP/floor.line" ] && [ -s "$TMP/spec.line" ] \
        && [ "$(head -1 "$TMP/floor.line")" -lt "$(head -1 "$TMP/spec.line")" ]; then
    ok "the floor is checked before the spec is sourced"
else
    bad "the floor must be checked before 'source \$SPEC'"
fi

# ... and the honest FAIL path must survive it: VGATE_COMPLETED is set past the
# assert loop and before the result block, so a real FAIL still exits 1 instead
# of being rewritten as the guard's 2.
awk '/^VGATE_COMPLETED=1$/{c=NR} /=== result ===/{r=NR} END{exit !(c && r && c < r)}' tools/gate/vgate.sh \
    && ok "VGATE_COMPLETED is set before the result block (a real FAIL keeps rc=1)" \
    || bad "VGATE_COMPLETED must be set before the result block, or every FAIL reads as 2"

# Issue #1503: a stale .build/go/GOSH.ELF must die in the harness as a named
# build error, not at VM boot as a behavioral assert. The check is in vgate.sh
# (fail closed) and must run before zig build; fleet.sh is the one rebuild.
if grep -q 'ensure-guest-elf.sh' tools/gate/vgate.sh; then
    ok "vgate.sh calls ensure-guest-elf.sh (issue #1503)"
else
    bad "vgate.sh must fail closed on a stale GOSH.ELF / GOSSHD.ELF"
fi
check_line="$(grep -n 'ensure-guest-elf.sh' tools/gate/vgate.sh | head -1 | cut -d: -f1)"
zig_line="$(grep -n '^    zig build$' tools/gate/vgate.sh | head -1 | cut -d: -f1)"
if [ -n "$check_line" ] && [ -n "$zig_line" ] && [ "$check_line" -lt "$zig_line" ]; then
    ok "guest-ELF freshness is checked before zig build (line $check_line < $zig_line)"
else
    bad "ensure-guest-elf check must run before zig build (check=$check_line zig=$zig_line)"
fi

# Exercise the shipped k4o hook, not a copy of its cleanup assertions.
echo
echo "── live-k4o cleanup evidence (no VM) ──"
if run python3 - "$TMP" <<'PY'
import json, os, pathlib, sys
from unittest.mock import patch

root = pathlib.Path(sys.argv[1]) / "k4o"
(root / "expected").mkdir(parents=True)
cases = [{"id": f"case-{i}", "binary": "K4OTEST.BIN" if i % 7 == 0 else "K4O.BIN",
          "status": 70 if i % 5 == 0 else 0} for i in range(212)]
(root / "expected/cases.json").write_text(json.dumps(cases))
hook = pathlib.Path("tools/gate/specs/live-k4o.spec").read_text().split(
    "vgate_file check.py <<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
page = "pages: armed=1 total=0x1000 free=0x0800\n"
pool = "tasks: enabled=1 current=0 switches=1 pool=3/16 zombies=0\n"
reap = "tasks user-exec reaped\n"
exit_ok = "procs K4OGATE.BIN exited status=0\n"
calls = "72 sys_getrandom calls=0\n73 sys_thread calls=0\n74 sys_futex calls=0\n"

def process(name, status, pid):
    return f"procs: id={pid} name={name} uid=1000 caps=0 state=exited task=reaped stack=0x1000 exit={status}\n"

def transcript(batch, late):
    selected = cases[batch * 12:(batch + 1) * 12]
    work = "".join("k4o-gate: case " + c["id"] + "\n" for c in selected)
    work += "k4o-gate: ArgumentLimit native length/count\n"
    work += f"k4o-gate: done cases={len(selected)}\n"
    reports = exit_ok + reap * (len(selected) + 1)
    snapshot = pool.replace("switches=1", "switches=99") + page
    snapshot += process("K4OGATE.BIN", 0, 1)
    snapshot += "".join(process(c["binary"], c["status"], i + 2) for i, c in enumerate(selected))
    snapshot += calls
    return pool + page + work + (snapshot + reports if late else reports + snapshot)

count = 0
def expect(label, serial, batch=0, succeeds=False):
    global count
    path = root / "serial.log"
    path.write_text(serial)
    env = dict(RUN_DIR=str(root), VG_SER=str(path), VG_TAG=f"b{batch}", VG_SHARE=str(root / "share"))
    with patch.dict(os.environ, env), patch("subprocess.run") as compare:
        try:
            exec(compile(hook, "live-k4o.spec:check.py", "exec"), {})
            passed = True
        except AssertionError:
            passed = False
        assert passed == succeeds, label
        assert compare.call_count == int(passed), label + ": byte comparison must follow successful assertions"
        if passed:
            args, = compare.call_args.args
            assert args[:4] == ["python3", "tools/zig/k4o/check.py", "compare", "--share"]
            assert compare.call_args.kwargs == {"check": True}
    count += 1

for batch in (0, 17):
    for late in (False, True):
        expect(f"complete batch {batch}, late={late}", transcript(batch, late), batch, True)
serial = transcript(0, True)
expect("dropped deferred reports", serial.replace(reap, "").replace(exit_ok, ""), succeeds=True)
expect("unreaped task slot", serial.replace("switches=99 pool=3", "switches=99 pool=4"))
expect("zombie awaiting reap", serial.replace("switches=99 pool=3/16 zombies=0", "switches=99 pool=4/16 zombies=1"))
expect("nonzero baseline zombies", serial.replace("zombies=0", "zombies=1"))
expect("missing task snapshot", serial.replace(pool, "", 1))
expect("missing launcher", serial.replace(process("K4OGATE.BIN", 0, 1), ""))
expect("failed launcher", serial.replace(process("K4OGATE.BIN", 0, 1), process("K4OGATE.BIN", 70, 1)))
child = process(cases[0]["binary"], cases[0]["status"], 2)
expect("missing child exit", serial.replace(child, ""))
expect("duplicate child exit", serial + child)
expect("wrong child status", serial.replace(child, process(cases[0]["binary"], 0, 2)))
expect("wrong child binary", serial.replace(child, process("K4O.BIN", cases[0]["status"], 2)))
expect("running child", serial.replace(child, child.replace("state=exited", "state=running")))
expect("page leak", serial.replace(page, page.replace("0x0800", "0x07ff"), 1))
expect("changed total", serial.replace(page, page.replace("0x1000", "0x1001"), 1))
expect("missing snapshot", serial.replace(page, "", 1))
expect("snapshot before workload", page * 2 + serial.replace(page, ""))
expect("task snapshot before workload", serial.replace(pool, pool * 2, 1).replace(
    pool.replace("switches=1", "switches=99"), ""))
expect("missing case", serial.replace("k4o-gate: case case-0\n", ""))
expect("child failure", serial + "k4o-gate: FAIL\n")
expect("native exception", serial + "[EXC]\n")
expect("forbidden call", serial.replace("72 sys_getrandom calls=0", "72 sys_getrandom calls=1"))
print(f"live-k4o: {count} cleanup/order/exit/resource regression cases passed")
PY
then
    ok "$CASE_OUT"
else
    bad "live-k4o cleanup regression: $CASE_OUT"
fi

# --- M131b (#2639, ADR 0059): warm-checkpoint legs through real vgate.sh ----
# A stub VMRunner shell script stands in for the binary (codesign is stubbed,
# so it reads as entitled; VZ_RUNNER_BIN retargets the invocation). It never
# boots a VM: save writes a canned bundle, load restores iff the clone's
# state.vzsave still carries its magic (truncation => the real rc-75 refusal
# shape), cold writes a boot banner + the leg's script into --serial.
echo
echo "── warm-checkpoint legs (ADR 0059, stub runner, no VM) ──"

# Same convention as the premature-exit block above: these cases drive the
# real vgate.sh end to end, so they need a shell that clears the floor.
# Literal `bash` is /bin/bash 3.2 under CI's job PATH, where every leg's
# verdict collapsed into the floor's rc=2 refusal (job 117845817253).
# Drive through $MODERN_BASH; where no modern bash exists, skip loudly
# like the block above.
if [ -n "$MODERN_BASH" ]; then

STUB_RUNNER="$TMP/vmrunner-stub"
cat > "$STUB_RUNNER" <<'SH'
#!/usr/bin/env bash
serial=""; script=""; expect=""; save=""; load=""
for a in "$@"; do
    # M131c (#2640): an empty argv element is a corrupted flag vector — the
    # real runner treats it as the legacy positional serial path. The stub
    # refuses it so a bad splice (e.g. `printf %q` on zero args emitting
    # `''`) fails loudly instead of passing through invisibly.
    [ -z "$a" ] && { echo "stub-runner: empty argv element" >&2; exit 73; }
done
while [ $# -gt 0 ]; do
    case "$1" in
        --serial) serial="$2"; shift 2 ;;
        --script) script="$2"; shift 2 ;;
        --script-expect) expect="$2"; shift 2 ;;
        --vz-restore-save) save="$2"; shift 2 ;;
        --vz-restore-load) load="$2"; shift 2 ;;
        *) shift ;;
    esac
done
# STUB_RUNNER_SLEEP simulates an in-flight VM: pause before producing any
# output so a test can signal the harness mid-run.
[ -n "${STUB_RUNNER_SLEEP:-}" ] && sleep "$STUB_RUNNER_SLEEP"
if [ -n "$save" ]; then
    [ -n "${STUB_VZ_LOG:-}" ] && echo save >> "$STUB_VZ_LOG"
    echo VZSTATE > "$save/state.vzsave"
    echo OVL > "$save/overlay.asif"
    echo MID > "$save/machine-id.bin"
    echo "VZ-RESTORE: SAVE PASS stub"
    exit 0
fi
if [ -n "$load" ]; then
    [ -n "${STUB_VZ_LOG:-}" ] && echo load >> "$STUB_VZ_LOG"
    if [ "$(head -c 7 "$load/state.vzsave" 2>/dev/null)" != "VZSTATE" ]; then
        echo "VZ-RESTORE: refused code=12"
        exit 75
    fi
    [ -n "$serial" ] && { cat "$script" > "$serial" 2>/dev/null; [ -n "$expect" ] && echo "$expect" >> "$serial"; }
    echo "VZ-RESTORE: warm leg seated — arming the leg's script over the post-restore epoch (stub)"
    exit 0
fi
[ -n "${STUB_VZ_LOG:-}" ] && echo cold >> "$STUB_VZ_LOG"
if [ -n "$serial" ]; then
    {
        echo "VirelaiOS kernel has seized control."
        echo "tasks user-el0 reaped"
        cat "$script" 2>/dev/null
        [ -n "$expect" ] && echo "$expect"
    } > "$serial"
fi
exit 0
SH
chmod +x "$STUB_RUNNER"

# gate_begin needs the canonical overlay base; a placeholder suffices — the
# stub never reads it. Remove it afterwards iff we created it.
CREATED_IMG=0
if [ ! -f artifacts/disk.img ]; then
    : > artifacts/disk.img; CREATED_IMG=1
fi

WARM_SPEC="$TMP/warm-mini.spec"
cat > "$WARM_SPEC" <<'SPEC'
vgate_name warm-mini "stub-runner warm-leg plumbing check"
vgate_share arm-virtiofs
vgate_file s1.txt <<'EOF'
echo c1-line
EOF
vgate_file s2.txt <<'EOF'
echo w1-line
EOF
vgate_file s3.txt <<'EOF'
echo w1b-line
EOF
vgate_file s4.txt <<'EOF'
echo s1-line
EOF
vgate_file s5.txt <<'EOF'
echo f1-line
EOF
vgate_checkpoint ck --
vgate_run c1 -- --script '$RUN_DIR/s1.txt' --script-after 'tasks user-el0 reaped' --script-expect c1-line --timeout 120
vgate_assert c1 serial-contains 'c1-line'
vgate_run w1 --from-checkpoint ck --warm-strict -- --script '$RUN_DIR/s2.txt' --script-after 'tasks user-el0 reaped' --script-expect w1-line --timeout 120
vgate_assert w1 serial-contains 'w1-line'
vgate_assert w1 serial-absent 'VirelaiOS kernel has seized control.'
vgate_assert w1 output-contains 'warm leg seated'
vgate_run w1b --from-checkpoint ck -- --script '$RUN_DIR/s3.txt' --script-after 'tasks user-el0 reaped' --script-expect w1b-line --timeout 120
vgate_assert w1b serial-contains 'never-emitted'
vgate_run s1 --from-checkpoint ck --warm-strict --warm-corrupt truncate-state -- --script '$RUN_DIR/s4.txt' --script-after 'tasks user-el0 reaped' --script-expect s1-line --timeout 120
vgate_assert s1 output-contains 'VZ-RESTORE: refused code='
vgate_run f1 --from-checkpoint ck --warm-corrupt truncate-state -- --script '$RUN_DIR/s5.txt' --script-after 'tasks user-el0 reaped' --script-expect f1-line --timeout 120
vgate_assert f1 serial-contains 'f1-line'
vgate_assert f1 python <<'PY'
import os
from pathlib import Path
warm = Path(os.environ["RUN_DIR"]) / "run-f1-warm.out"
assert warm.exists(), "the refused warm attempt's output must be kept as evidence"
assert "VZ-RESTORE: refused code=" in warm.read_text()
PY
SPEC

: > "$TMP/stub.log"
STUB_CODESIGN_OUT="$ENTITLED_OUT" STUB_CODESIGN_RC=0
export STUB_CODESIGN_OUT STUB_CODESIGN_RC
STUB_HV_NAME=HV_SUCCESS STUB_HV_CODE=0x00000000
export STUB_HV_NAME STUB_HV_CODE
VZ_HV_PROBE_BIN="$STUB_PROBE"
export VZ_HV_PROBE_BIN

VGATE_NO_BUILD=1 VZ_RUNNER_BIN="$STUB_RUNNER" STUB_VZ_LOG="$TMP/stub.log" \
    VIRELAI_RUN_DIR_BASE="$TMP" VIRELAI_KEEP_RUN=1 \
    "$MODERN_BASH" tools/gate/vgate.sh "$WARM_SPEC" > "$TMP/vgate-warm.out" 2>&1
warm_rc=$?

RUN_DIR_LEFT="$(ls -d "$TMP"/virelai-warm-mini.* 2>/dev/null | head -1)"

# The stub's refusal path + the strict leg make the gate FAIL overall (w1b's
# deliberately failing assert + s1's strict refusal), but every leg's receipt
# must still be written.
[ "$warm_rc" = 1 ] && ok "vgate exits 1 on the mixed PASS/FAIL warm spec (rc=$warm_rc)" \
    || { bad "warm spec should exit 1, got rc=$warm_rc"; sed -n '1,15p' "$TMP/vgate-warm.out" | sed 's/^/      /'; }

gate_report_file="artifacts/warm-mini-report.txt"
[ -f "$gate_report_file" ] || { bad "no report file at $gate_report_file"; gate_report_file=/dev/null; }

grep -q '^c1: PASS warm=cold$' "$gate_report_file" \
    && ok "a plain vgate_run records warm=cold" \
    || { bad "c1 should read 'PASS warm=cold'"; grep '^c1:' "$gate_report_file" | sed 's/^/      /'; }
grep -q '^w1: PASS warm=restored$' "$gate_report_file" \
    && ok "the strict warm leg records warm=restored" \
    || { bad "w1 should read 'PASS warm=restored'"; grep '^w1:' "$gate_report_file" | sed 's/^/      /'; }
grep -q '^w1b: FAIL warm=restored$' "$gate_report_file" \
    && ok "a restored leg whose assert fails records FAIL warm=restored (no cold substitute)" \
    || { bad "w1b should read 'FAIL warm=restored'"; grep '^w1b:' "$gate_report_file" | sed 's/^/      /'; }
grep -q '^s1: FAIL warm=refused(12)$' "$gate_report_file" \
    && ok "a refused strict leg records warm=refused(<code>)" \
    || { bad "s1 should read 'FAIL warm=refused(12)'"; grep '^s1:' "$gate_report_file" | sed 's/^/      /'; }
grep -q '^f1: PASS warm=fallback(12)$' "$gate_report_file" \
    && ok "a refused non-strict leg degrades once and records warm=fallback(<code>)" \
    || { bad "f1 should read 'PASS warm=fallback(12)'"; grep '^f1:' "$gate_report_file" | sed 's/^/      /'; }
grep -q 'ckpt-ck: PASS' "$gate_report_file" \
    && ok "the checkpoint base boot reports its own PASS row" \
    || bad "ckpt-ck PASS row missing from the report"

# Invocation census: 1 save, 4 loads (w1, w1b, s1, f1), 2 colds (c1 + f1's
# fallback) — an assert failure must NOT have fired a cold rerun (D8).
n_save="$(grep -c '^save$' "$TMP/stub.log" || true)"
n_load="$(grep -c '^load$' "$TMP/stub.log" || true)"
n_cold="$(grep -c '^cold$' "$TMP/stub.log" || true)"
[ "$n_save" = 1 ] && ok "exactly one base boot ran (save=$n_save)" \
    || bad "expected 1 save, got $n_save"
[ "$n_load" = 4 ] && ok "each warm leg attempted restore exactly once (load=$n_load)" \
    || bad "expected 4 loads, got $n_load"
[ "$n_cold" = 2 ] && ok "cold boots only for the plain leg + the fallback leg (cold=$n_cold — assert failures never re-run)" \
    || bad "expected 2 colds, got $n_cold"

# D3: the bundle carries every member and each leg cloned its own copy.
if [ -n "$RUN_DIR_LEFT" ] && [ -d "$RUN_DIR_LEFT/ckpt-ck" ]; then
    for m in state.vzsave overlay.asif efi-vars.bin machine-id.bin; do
        [ -f "$RUN_DIR_LEFT/ckpt-ck/$m" ] \
            && ok "bundle member $m present" \
            || bad "bundle member $m missing from ckpt-ck"
    done
    [ -d "$RUN_DIR_LEFT/ckpt-ck/share" ] \
        && ok "bundle pins the armed share/ (arm-virtiofs)" \
        || bad "bundle share/ missing"
    [ -f "$RUN_DIR_LEFT/warm-w1/state.vzsave" ] && [ -d "$RUN_DIR_LEFT/warm-w1/share" ] \
        && ok "w1 got its own state+share clones" \
        || bad "w1's warm-<tag> clone set incomplete"
    [ -f "$RUN_DIR_LEFT/warm-f1/state.vzsave" ] \
        && ok "f1 got its own clones" \
        || bad "f1's warm-<tag> clone set incomplete"
else
    bad "no ckpt-ck bundle under $RUN_DIR_LEFT"
fi
rm -rf "$RUN_DIR_LEFT" 2>/dev/null
rm -f artifacts/warm-mini-*

# VGATE_WARM=off: no base boot, every --from-checkpoint leg cold, warm=cold.
: > "$TMP/stub.log"
VGATE_NO_BUILD=1 VGATE_WARM=off VZ_RUNNER_BIN="$STUB_RUNNER" STUB_VZ_LOG="$TMP/stub.log" \
    VIRELAI_RUN_DIR_BASE="$TMP" \
    "$MODERN_BASH" tools/gate/vgate.sh "$WARM_SPEC" > "$TMP/vgate-warm-off.out" 2>&1
off_rc=$?
n_save_off="$(grep -c '^save$' "$TMP/stub.log" || true)"
n_load_off="$(grep -c '^load$' "$TMP/stub.log" || true)"
n_cold_off="$(grep -c '^cold$' "$TMP/stub.log" || true)"
# c1/w1b/f1 run cold; the two strict legs fail WITHOUT an invocation — under
# off nothing can restore, so warm=cold can never satisfy a strict pin.
[ "$n_save_off" = 0 ] && [ "$n_load_off" = 0 ] && [ "$n_cold_off" = 3 ] \
    && ok "VGATE_WARM=off: no base boot, non-strict warm legs cold (save=0 load=0 cold=$n_cold_off)" \
    || bad "VGATE_WARM=off census wrong: save=$n_save_off load=$n_load_off cold=$n_cold_off"
grep -q '^w1: FAIL warm=cold$' "artifacts/warm-mini-report.txt" \
    && ok "a strict leg under VGATE_WARM=off records FAIL warm=cold (nothing can restore)" \
    || { bad "w1 under off should read 'FAIL warm=cold'"; grep '^w1:' artifacts/warm-mini-report.txt | sed 's/^/      /'; }
grep -q '^f1: FAIL warm=cold$' "artifacts/warm-mini-report.txt" \
    && ok "a non-strict warm leg under VGATE_WARM=off records warm=cold (FAIL here only because f1's assert requires a refused warm attempt, which off never makes)" \
    || { bad "f1 under off should read 'FAIL warm=cold'"; grep '^f1:' artifacts/warm-mini-report.txt | sed 's/^/      /'; }
rm -f artifacts/warm-mini-*

# --- spec-load refusals (ADR 0059 D8's static Code=2 class) -------------------
# These die before any build/boot machinery, so no stubs need to satisfy them
# beyond the codesign/hv env already exported.
refuse() {  # refuse <label> <spec-path> <expected-substring>
    local label="$1" spec="$2" want="$3" out rc
    out="$(VGATE_NO_BUILD=1 "$MODERN_BASH" tools/gate/vgate.sh "$spec" 2>&1)"; rc=$?
    if [ "$rc" = 2 ] && printf '%s' "$out" | grep -qF -- "$want"; then
        ok "$label"
    else
        bad "$label — rc=$rc, want '$want': $(printf '%s' "$out" | tail -3 | tr '\n' '|')"
    fi
}

cat > "$TMP/refuse-allowlist.spec" <<'SPEC'
vgate_name refuse-allowlist "x"
vgate_checkpoint ck -- --timeout 240
vgate_run w --from-checkpoint ck -- --script /tmp/x --cpus 4 --timeout 60
SPEC
refuse "the warm-leg allow-list refuses a device flag (--cpus)" \
    "$TMP/refuse-allowlist.spec" "outside the warm-leg allow-list"

cat > "$TMP/refuse-cvc.spec" <<'SPEC'
vgate_name refuse-cvc "x"
vgate_checkpoint ck -- --custom-virtio --timeout 240
vgate_run w --from-checkpoint ck -- --script /tmp/x --timeout 60
SPEC
refuse "a custom-virtio flag on vgate_checkpoint refuses at spec load" \
    "$TMP/refuse-cvc.spec" "unsaveable (ADR 0059 D1)"

cat > "$TMP/refuse-share.spec" <<'SPEC'
vgate_name refuse-share "x"
vgate_share arm
vgate_checkpoint ck -- --timeout 240
vgate_run w --from-checkpoint ck -- --script /tmp/x --timeout 60
SPEC
refuse "vgate_share arm + --from-checkpoint refuses (the armed --cvc-file is unsaveable)" \
    "$TMP/refuse-share.spec" "unsaveable (ADR 0059 D1)"

cat > "$TMP/refuse-unknown.spec" <<'SPEC'
vgate_name refuse-unknown "x"
vgate_run w --from-checkpoint nope -- --script /tmp/x --timeout 60
SPEC
refuse "--from-checkpoint of an undeclared checkpoint refuses" \
    "$TMP/refuse-unknown.spec" "no 'vgate_checkpoint nope' declared"

cat > "$TMP/refuse-client.spec" <<'SPEC'
vgate_name refuse-client "x"
vgate_checkpoint ck -- --timeout 240
vgate_run w --from-checkpoint ck -- --script /tmp/x --timeout 60
vgate_client w -- --connect 127.0.0.1:9
SPEC
refuse "vgate_client on a warm leg refuses (host state outside the bundle)" \
    "$TMP/refuse-client.spec" "ADR 0059 D7(c)"

cat > "$TMP/refuse-strict-bare.spec" <<'SPEC'
vgate_name refuse-strict-bare "x"
vgate_checkpoint ck -- --timeout 240
vgate_run w --warm-strict -- --script /tmp/x --timeout 60
SPEC
refuse "--warm-strict without --from-checkpoint refuses" \
    "$TMP/refuse-strict-bare.spec" "require --from-checkpoint"

# The strict refusal path keeps the refused attempt's output as the leg's
# evidence — already covered by s1's output-contains assert above, which only
# holds if run-s1.out IS the refused warm attempt.

# --- run-dir teardown on signal exit ----------------------------------------
# gate_begin mktemp's $VIRELAI_RUN_DIR_BASE/virelai-<gate>.XXXXXX and installs
# INT/TERM traps that run gate_end and exit 128+sig, so a signal exit tears
# down the staging dir instead of leaking it. Drive the REAL vgate.sh with
# the stub runner sleeping in place of a VM, so the signal lands while a
# foreground child owns the shell's wait.
#
# Delivery matters: an async child of this non-interactive suite inherits
# SIGINT ignored — a disposition a shell cannot then trap (POSIX). The
# launcher below resets it and puts vgate in its own session, so INT can be
# delivered to the whole process group exactly like a terminal's ^C. TERM
# goes to the harness alone — bash defers a trapped TERM until the foreground
# child exits, so the TERM case takes up to STUB_RUNNER_SLEEP seconds.
echo
echo "── run-dir teardown on signal exit ──"

SIG_SPEC="$TMP/sig-mini.spec"
cat > "$SIG_SPEC" <<'SPEC'
vgate_name sig-mini "stub-runner signal teardown check"
vgate_file s1.txt <<'EOF'
echo sig-line
EOF
vgate_run 01 -- --script '$RUN_DIR/s1.txt' --script-after 'tasks user-el0 reaped' --script-expect sig-line --timeout 120
vgate_assert 01 serial-contains 'sig-line'
SPEC

for sig in TERM INT; do
    VGATE_NO_BUILD=1 VZ_RUNNER_BIN="$STUB_RUNNER" STUB_RUNNER_SLEEP=6 \
        VIRELAI_RUN_DIR_BASE="$TMP" \
        python3 - "$MODERN_BASH" "$SIG_SPEC" > "$TMP/vgate-sig-$sig.out" 2>&1 <<'PY' &
import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.setsid()
os.execvpe(sys.argv[1], [sys.argv[1], "tools/gate/vgate.sh", sys.argv[2]], os.environ)
PY
    sig_vgpid=$!
    # Wait for the run dir to exist AND the stub to be in-flight (inside its
    # sleep), so the signal lands mid-run.
    sig_dir=""
    for _ in $(seq 40); do
        sig_dir="$(ls -d "$TMP"/virelai-sig-mini.* 2>/dev/null | head -1)"
        [ -n "$sig_dir" ] && pgrep -f "$STUB_RUNNER" >/dev/null 2>&1 && break
        sleep 0.25
    done
    if [ "$sig" = INT ]; then
        kill -INT -- -"$sig_vgpid" 2>/dev/null   # ^C: the whole session group
    else
        kill -TERM "$sig_vgpid" 2>/dev/null      # watchdog: the harness alone
    fi
    wait "$sig_vgpid"; sig_rc=$?
    [ "$sig_rc" != 0 ] \
        && ok "SIG$sig mid-run: vgate exits nonzero (rc=$sig_rc)" \
        || bad "SIG$sig mid-run: vgate reported rc=0 — the interrupt was swallowed"
    [ -n "$sig_dir" ] && [ ! -d "$sig_dir" ] \
        && ok "SIG$sig mid-run: run dir removed" \
        || bad "SIG$sig mid-run: run dir still present: ${sig_dir:-<none created>}"
    pgrep -f "$STUB_RUNNER" >/dev/null 2>&1 && pkill -f "$STUB_RUNNER" || true
done
rm -f artifacts/sig-mini-*

rm -rf "$RUN_DIR_LEFT" 2>/dev/null
rm -f artifacts/warm-mini-* artifacts/refuse-*-report.txt artifacts/refuse-*-gate.txt
[ "$CREATED_IMG" = 1 ] && rm -f artifacts/disk.img

else
    echo "  skip  no bash >= 4.4 anywhere on this host (running: $BASH_VERSION): the"
    echo "  skip  warm-leg scenarios drive the real vgate.sh end to end; the floor"
    echo "  skip  they sit behind is asserted above."
fi

# --- the real probe: it must build, and carry the right entitlement --------
echo
echo "── the shipped probe (no stubs) ──"

if command -v clang >/dev/null 2>&1; then
    # The REAL codesign, not the stub: this section builds and signs the shipped
    # probe for real. (Left stubbed, it silently produced an unsigned probe that
    # reported HV_DENIED -- the stub caught itself.)
    PATH="$ORIG_PATH"
    # The default source/entitlement paths, a throwaway binary.
    export VZ_HV_PROBE_SRC VZ_HV_PROBE_ENT
    REAL_BIN="$TMP/real-hvprobe"
    VZ_HV_PROBE_BIN="$REAL_BIN"
    export VZ_HV_PROBE_BIN
    if gate_build_hv_probe; then
        ok "the shipped probe compiles"
        real_out="$("$REAL_BIN" 2>/dev/null || true)"
        case "$real_out" in
            *HV_NAME=HV_*) ok "it runs and reports a recognised HV code ($(printf '%s' "$real_out" | sed -n 's/.*HV_NAME=\([A-Z_]*\).*/\1/p' | head -1))" ;;
            *) bad "it should print an HV_NAME: $real_out" ;;
        esac
        case "$(codesign -d --entitlements - "$REAL_BIN" 2>&1)" in
            *"com.apple.security.hypervisor"*) ok "it carries com.apple.security.hypervisor" ;;
            *) bad "the probe must be signed with the hypervisor entitlement" ;;
        esac
        # The arm64 header point: hv.h is x86-only, so this only builds if the
        # source uses the umbrella header.
        grep -q '<Hypervisor/Hypervisor.h>' tools/gate/hv-probe.c \
            && ok "hv-probe.c includes <Hypervisor/Hypervisor.h>" \
            || bad "hv-probe.c must include the arm64 umbrella header"
    else
        bad "the shipped probe failed to build"
    fi
else
    echo "  skip  clang not available; the shipped probe was not built here"
fi

# Restore the stub for any later cases.
VZ_HV_PROBE_BIN="$STUB_PROBE"
export VZ_HV_PROBE_BIN

echo
if [ "$FAIL" = 0 ]; then
    echo "test-gate-run: PASS — $PASS case(s): both preflight failure modes, and the exit-ZERO false-PASS guard (issue #1338)."
    exit 0
fi
echo "test-gate-run: FAIL — $FAIL of $((PASS + FAIL)) case(s) failed."
exit 1
