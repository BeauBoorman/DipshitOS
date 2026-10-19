#!/usr/bin/env bash
#
# fleet.sh -- the gate fleet, discovered from the spec dir (M40 GF5, issue
# #940). The spec list under tools/gate/specs/ is the single source of
# truth: every entry point (the `just gate`/`just gates`/`just verify-vz`
# recipes, the vz-gates.yml CI shards, docs/gate-inventory.md) is derived
# from what this library finds on disk. Adding or removing a spec file
# changes every entry point with zero list edits anywhere.
#
# The fleet is ALL of:
#   - every tools/gate/specs/*.spec (run through tools/gate/vgate.sh), plus
#   - the LEGACY_SCRIPTS below: the four class-B gates that predate the
#     spec format and were sharded by the pre-GF5 archive GATE block.
#     serial-takeover (`zig build run`) is deliberately NOT in the fleet:
#     it is an interactive console takeover (needs a TTY) and is excluded
#     from automation exactly as it was before GF5. Run it with `just run`.
#
# Suites are not curated lists: `gates <pattern>` runs every fleet member
# whose id contains the pattern as a substring. There is nothing to
# maintain — a new spec named live-foo-* is immediately in `just gates foo`.
#
# Subcommands (also usable directly, no `just` required):
#   list              one "kind<TAB>id" line per fleet member, LC_ALL=C
#                     sorted (kind: spec | script) — what CI shards on
#   count             member count
#   ids [pattern]     member ids, optionally substring-filtered
#   census [pattern]  per-spec warm-checkpoint leg census (ADR 0059 D1+D7):
#                     legs / device-ineligible / semantic a-f / adopted /
#                     unclassified, plus a FLEET row — parses specs, boots
#                     nothing; `--legs` adds per-leg verdicts
#   match <pattern>   ids matching a substring (errors when none)
#   resolve <id>      echo the id for an exact name or unique prefix
#   run <id|pattern>...  run the named members (or pattern groups), fail
#                        at the end if any failed; evidence under artifacts/
#   verify-vz         run the WHOLE fleet sequentially (the `just verify-vz`
#                     body). BOOTS/VIRELAI_GATE_SUFFIX/... pass through to
#                     vgate.sh exactly as documented in tools/gate/SPEC.md.
#
# Environment: VIRELAI_GATE_SUFFIX, VGATE_NO_BUILD, BOOTS honored by
# vgate.sh. Before running selected specs, fleet.sh hash-checks (and
# rebuilds if needed) .build/go/GOSH.ELF / GOSSHD.ELF once per invocation
# (issue #1503) so a leftover hand-built binary cannot reach a guest.
#
# Dev-shell note (the one canonical PATH paragraph): fleet members need the
# modern Homebrew toolchain exactly like CI — /opt/homebrew/bin FIRST and
# /opt/homebrew/opt/gnu-sed/libexec/gnubin for GNU sed. That is byte-for-byte
# what .github/workflows/vz-gates.yml ("Put Homebrew toolchain on PATH") and
# .github/workflows/ci.yml set up. Locally, `source tools/env-check.sh`
# verifies the same thing and complains loudly when the 2007-era system
# bash/sed win instead.
#
set -euo pipefail

FLEET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$FLEET_DIR/../.." && pwd)"

# Class-B gates that predate the spec format (kept as scripts, sharded
# alongside the specs since before GF5). Do not add to this list: new gates
# arrive as specs (tools/gate/SPEC.md, the M40 GF1 freeze).
LEGACY_SCRIPTS=(
    verify-bad-handoff
    verify-marker
    verify-nvram-console
    verify-host-console
)

SPEC_DIR="$ROOT/tools/gate/specs"

fleet_specs() {
    # Sorted spec ids (basename without .spec).
    local f
    for f in $(LC_ALL=C ls "$SPEC_DIR"/*.spec 2>/dev/null | LC_ALL=C sort); do
        basename "$f" .spec
    done
}

fleet_ids() {
    # The whole fleet, LC_ALL=C sorted: specs + legacy scripts merged,
    # so sharding math is stable regardless of member kind.
    { fleet_specs; printf '%s\n' "${LEGACY_SCRIPTS[@]}"; } | LC_ALL=C sort
}

fleet_kind() {
    # kind of one id: spec | script (assumes the id is a fleet member)
    case " ${LEGACY_SCRIPTS[*]} " in
        *" $1 "*) echo "script" ;;
        *)        echo "spec" ;;
    esac
}

fleet_match() {
    # All ids whose name contains $1 as a substring.
    local pat="$1" id hits=0
    while IFS= read -r id; do
        case "$id" in
            *"$pat"*) echo "$id"; hits=$((hits + 1)) ;;
        esac
    done < <(fleet_ids)
    [ "$hits" -gt 0 ] || { echo "fleet: no member matches '$pat'" >&2; return 2; }
}

fleet_resolve() {
    # Exact id, else unique prefix. Errors (rc=2) listing candidates.
    local want="$1" id exact="" hits=0
    while IFS= read -r id; do
        if [ "$id" = "$want" ]; then exact="$id"; break; fi
        case "$id" in "$want"*) hits=$((hits + 1)); echo "$id" ;; esac
    done < <(fleet_ids)
    if [ -n "$exact" ]; then echo "$exact"; return 0; fi
    if [ "$hits" -eq 1 ]; then return 0; fi   # unique prefix candidates already printed
    if [ "$hits" -gt 1 ]; then
        echo "fleet: '$want' is ambiguous ($hits prefix matches) — name it fully" >&2
        return 2
    fi
    echo "fleet: no member '$want' (see: bash tools/gate/fleet.sh ids)" >&2
    return 2
}

fleet_run_one() {
    # Run one member; echo its id; rc = the member's rc.
    local id="$1" kind
    kind="$(fleet_kind "$id")"
    case "$kind" in
        spec)   bash "$ROOT/tools/gate/vgate.sh" "$SPEC_DIR/$id.spec" ;;
        script) bash "$ROOT/tools/$id.sh" ;;
    esac
}

fleet_select() {
    # One arg -> matching member ids. An arg that IS an exact member id
    # selects exactly itself; anything else goes through prefix matching.
    # (M40 GF6 fix: verify-vz passes full ids; routing them through the
    # prefix matcher re-expanded short ids like live-win into every
    # live-win-* member and ran 24 gates twice.)
    local want="$1" id
    while IFS= read -r id; do
        [ "$id" = "$want" ] && { echo "$want"; return 0; }
    done < <(fleet_ids)
    fleet_match "$want"
}

fleet_ensure_guest_elfs() {
    # Issue #1503: rebuild GOSH.ELF / GOSSHD.ELF at most once per fleet
    # invocation when a selected spec stages them. Hash-cached inside
    # ensure-guest-elf.sh — a matching stamp is a no-op, so this is not a
    # per-spec Go rebuild.
    local id spec app seen=" "
    for id in "$@"; do
        [ "$(fleet_kind "$id")" = spec ] || continue
        spec="$SPEC_DIR/$id.spec"
        [ -f "$spec" ] || continue
        while IFS= read -r app; do
            [ -n "$app" ] || continue
            case "$seen" in *" $app "*) continue ;; esac
            seen="$seen$app "
            echo "fleet: ensure ${app}.ELF (issue #1503, hash-cached)"
            bash "$ROOT/tools/go/ensure-guest-elf.sh" ensure "$app"
        done < <(bash "$ROOT/tools/go/ensure-guest-elf.sh" needed-by "$spec")
    done
}

fleet_run() {
    # Run the given ids/patterns sequentially; continue past failures;
    # summary at the end; nonzero rc iff anything failed.
    local sel=() arg id
    for arg in "$@"; do
        while IFS= read -r id; do sel+=("$id"); done < <(fleet_select "$arg")
    done
    local total=${#sel[@]}
    [ "$total" -gt 0 ] || { echo "fleet: nothing selected" >&2; return 2; }

    local failed=() n=0 rc start
    echo "=== fleet run: $total member(s): ${sel[*]}"
    fleet_ensure_guest_elfs "${sel[@]}"
    for id in "${sel[@]}"; do
        n=$((n + 1))
        echo
        echo "--- [$n/$total] $(fleet_kind "$id") $id"
        start=$SECONDS
        set +e
        fleet_run_one "$id"
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
            echo "--- [$n/$total] PASS $id ($((SECONDS - start))s)"
        else
            echo "--- [$n/$total] FAIL $id rc=$rc ($((SECONDS - start))s)"
            failed+=("$id")
        fi
    done
    echo
    if [ "${#failed[@]}" -gt 0 ]; then
        echo "FLEET RESULT: $((total - ${#failed[@]}))/$total PASS — failed:${failed[*]/#/ }"
        return 1
    fi
    echo "FLEET RESULT: $total/$total PASS"
}

fleet_verify_vz() {
    # The whole fleet, in canonical (sorted) order.
    local ids=() id
    while IFS= read -r id; do ids+=("$id"); done < <(fleet_ids)
    fleet_run "${ids[@]}"
}

main() {
    [ $# -ge 1 ] || { sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 2; }
    local cmd="$1"; shift
    case "$cmd" in
        list)    local id; while IFS= read -r id; do
                     printf '%s\t%s\n' "$(fleet_kind "$id")" "$id"
                 done < <(fleet_ids) ;;
        count)   fleet_ids | wc -l | tr -d ' ' ;;
        ids)     if [ $# -gt 0 ]; then fleet_match "$1"; else fleet_ids; fi ;;
        match)   [ $# -eq 1 ] || { echo "fleet: match <pattern>" >&2; exit 2; }
                 fleet_match "$1" ;;
        census)  LC_ALL=C python3 "$FLEET_DIR/fleet-census.py" --spec-dir "$SPEC_DIR" "$@" ;;
        resolve) [ $# -eq 1 ] || { echo "fleet: resolve <id>" >&2; exit 2; }
                 fleet_resolve "$1" ;;
        run)     [ $# -ge 1 ] || { echo "fleet: run <id|pattern>..." >&2; exit 2; }
                 fleet_run "$@" ;;
        verify-vz) [ $# -eq 0 ] || { echo "fleet: verify-vz takes no arguments" >&2; exit 2; }
                 fleet_verify_vz ;;
        *) echo "fleet: unknown subcommand: $cmd" >&2; exit 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
