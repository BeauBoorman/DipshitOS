#!/usr/bin/env bash
#
# tools/env-check.sh -- source me at the start of every agent session.
#
#   source tools/env-check.sh          # or, from a clean PATH root, once at login
#
# WHY THIS EXISTS
# ---------------
# This repo's build + gate scripts rely on the *modern* Homebrew builds of
# the standard Unix tools. macOS ships 2007-era GNU bash 3.2 under
# /bin/bash, and the old BSD-flavored sed(1) under /usr/bin/sed. When a
# shell is spawned with /usr/bin or /bin ahead of Homebrew in PATH (exactly
# what fresh/non-interactive agents get), `bash` and `sed` silently resolve
# to the dogshit system versions and the gates act weird.
#
# We source this at session start so EVERY agent checks ONCE whether it is
# about to run bash 3.2 and BSD sed -- and bitches loudly when it is.
#
# IT DOES FOUR THINGS
# --------------------
#   1. Ensures the Homebrew bin dir is FIRST on PATH (defensively re-prepends
#      it; does *not* clobber anything else on your PATH).
#   2. For each tool the check knows about, resolves what `bash`/`sed`/...
#      actually point at and verifies the version/identity is the modern one.
#   3. Verbosely, in red, complains when it detects the system build -- and
#      returns non-zero from this file so a strict caller (an agent harness,
#      CI, `set -e` wrapper) can fail hard.
#   4. Diffs the GOOS=virelai toolchain FORK COPY against tools/go/overlay/
#      (issue #1648): a fork left behind by an overlay change builds every
#      Go ELF against the OLD runtime -- gates red for a reason no spec
#      prints. `bash tools/go/apply.sh` re-syncs it in place.
#
# It is safe to source repeatedly: it is idempotent and only writes STDOUT
# when something is wrong (or when VERBOSE=1).
#
# USAGE
# -----
#   VERBOSE=1 source tools/env-check.sh        # do the check, show the good bits too
#   source tools/env-check.sh || exit 1        # hard-fail if any tool is the system one
#
# The tool table is at the bottom: add a row (name, brew package, min
# version or identity matcher) and the loop handles it.
#
# DEPENDENCIES
# ------------
# Homebrew. On Apple silicon that is /opt/homebrew; on Intel /usr/local.
# Present a warning (not a failure) if Homebrew is missing -- the rest of
# the world still works -- and let the per-tool checks report specifics.

set -u

# ---- pretty printing (portable, no tput dependency) -------------------------
_ENV_RED=$'\033[0;31m'
_ENV_YELLOW=$'\033[0;33m'
_ENV_GREEN=$'\033[0;32m'
_ENV_BOLD=$'\033[1m'
_ENV_DIM=$'\033[2m'
_ENV_RESET=$'\033[0m'
_ENV_OK=1          # flip to 0 the instant anything is wrong
_ENV_RANTED=0      # ensure we only vomit the big complaint once

env_crit()  { printf '%s' "${_ENV_RED}${_ENV_BOLD}";  printf '%s\n' "$@"; printf '%s' "${_ENV_RESET}"; }
env_warn()  { printf '%s' "${_ENV_YELLOW}${_ENV_BOLD}"; printf '%s\n' "$@"; printf '%s' "${_ENV_RESET}"; }
env_good()  { printf '%s' "${_ENV_GREEN}";              printf '%s\n' "$@"; printf '%s' "${_ENV_RESET}"; }
env_dim()   { printf '%s' "${_ENV_DIM}";                printf '%s\n' "$@"; printf '%s' "${_ENV_RESET}"; }

# ---- find Homebrew ----------------------------------------------------------
find_brewbins() {
    local b
    for b in "${BREW_PREFIX:-}" /opt/homebrew/bin /usr/local/bin; do
        [ -d "$b" ] && { echo "$b"; return 0; }
    done
    return 1
}

# resolve a command to its absolute path WITHOUT following the final symlink
# (readlink -f is GNU-only; this walks dirname/name via the shell instead)
_resolve_no_follow() {
    # $1 = full path minus the final symlink we want to keep; we just echo the
    # command -v result, which is enough to detect /usr/bin vs /opt/homebrew.
    printf '%s\n' "$1"
}

# ---- the complaint ----------------------------------------------------------
rant() {
    # $1 = tool name, $2 = discovered path/version, $3 = fix hint
    [ "$_ENV_RANTED" = 1 ] || {
        _ENV_RANTED=1
        env_crit ""
        env_crit "╔══════════════════════════════════════════════════════════════════╗"
        env_crit "║   YOU ARE ABOUT TO RUN THE WRONG TOOLS, YOU MAGNIFICENT IDIOT.   ║"
        env_crit "╚══════════════════════════════════════════════════════════════════╝"
        env_crit ""
        env_crit "This repo (VirelaiOS) needs the MODERN Homebrew builds of the Unix"
        env_crit "toolchain. macOS still ships 2007-era /bin/bash 3.2 and BSD sed."
        env_crit "The build + gate scripts behave differently under those. Pretty sure"
        env_crit "you do not want to debug THAT again."
        env_crit ""
    }
    env_crit "  ✘  $1"
    env_crit "      saw:    ${2:-?}"
    env_crit "      fix:    ${3:-install the Homebrew version}"
    env_crit ""
    return 0
}

# ---- per-tool checks ---------------------------------------------------------
# each check_foo sets _ENV_OK=0 + calls rant() on failure.

check_bash() {
    local cur
    cur="$(command -v bash 2>/dev/null || true)"
    [ -n "$cur" ] || { _ENV_OK=0; rant bash "bash not found on PATH" "brew install bash; ensure /opt/homebrew/bin leads PATH"; return; }
    local ver
    ver="$(bash --version 2>/dev/null | head -1 || true)"
    case "$cur:$ver" in
        /bin/bash*|/usr/bin/*bash*)
            _ENV_OK=0
            rant bash "$cur — $ver" \
                "brew install bash, then ensure /opt/homebrew/bin comes BEFORE /bin in PATH"
            ;;
        *)
            # modern bash lives under /opt/homebrew (or /usr/local). Version >= 4 is
            # The Good Bash; 3.2 is the system one. Accept anything with 'version' >=4.
            case "$ver" in
                *"version 4"*|*"version 5"*|*"version 6"*|*"version 7"*|*"version 8"*|*"version 9"*) : ;;
                *) _ENV_OK=0; rant bash "$cur — $ver" "homebrew bash 5.x; check it is really first in PATH" ;;
            esac
            ;;
    esac
    return 0
}

check_sed() {
    local cur
    cur="$(command -v sed 2>/dev/null || true)"
    [ -n "$cur" ] || { _ENV_OK=0; rant sed "sed not found on PATH" "brew install gnu-sed"; return; }
    # GNU sed advertises itself; BSD sed doesn't.
    if sed --version 2>/dev/null | grep -qi 'GNU sed'; then
        return 0
    fi
    # not GNU sed. Could still be a modern BSD on a non-Darwin box; on Darwin
    # /usr/bin/sed is the 2005 system build. Check the path.
    case "$cur" in
        /bin/*|/usr/bin/*)
            _ENV_OK=0
            rant sed "$cur ($(sed --version 2>&1 | head -1)) — GNU sed NOT detected" \
                "brew install gnu-sed; env-check puts /opt/homebrew/opt/gnu-sed/libexec/gnubin on PATH (the same dir CI uses) — re-source if you skipped that"
            ;;
        *) : ;; # unknown platform, don't nag
    esac
    return 0
}

check_jq() {
    local cur
    cur="$(command -v jq 2>/dev/null || true)"
    [ -n "$cur" ] || return 0   # jq optional here
    local ver
    ver="$(jq --version 2>/dev/null || true)"
    # version-aware: jq backports are reported like "jq-1.7.1-apple";
    # only the major.minor matters. Need >= 1.6.
    local minor
    minor="$(printf '%s' "$ver" | sed 's/^jq-1\.//; s/\..*$//; s/^[^0-9].*//')"
    case "$ver" in
        jq-2*|jq-[0-9]*|[2-9]*)
            # major >= 2 -> definitely fine
            : ;;
        jq-1.*)
            # 1.y: need y >= 6
            if [ -n "$minor" ] && [ "$minor" -ge 6 ] 2>/dev/null; then :; else
                _ENV_OK=0; rant jq "$cur — $ver" "brew install jq (need >= 1.6)"
            fi
            ;;
        *)
            _ENV_OK=0; rant jq "$cur — $ver" "brew install jq (need >= 1.6)"
            ;;
    esac
    return 0
}

check_yq() {
    local cur
    cur="$(command -v yq 2>/dev/null || true)"
    [ -n "$cur" ] || return 0   # yq optional here
    # just confirm it is not the stale one sitting in the repo/image scripts
    case "$cur" in
        /bin/*|/usr/bin/*) : ;; # if it's under /usr/bin it's not brew; but yq is never there
        *) : ;;
    esac
    return 0
}

check_go_overlay() {
    # Issue #1648: the GOOS=virelai fork is a COPY, not a checkout --
    # tools/go/apply.sh provisions it once and then copies tools/go/overlay/
    # into it. When the overlay moves forward (a runtime/kernel contract
    # change like M71m's 256->4096-B argv block) and nobody re-runs
    # apply.sh, every Go ELF silently builds against the OLD runtime: a
    # pre-M71m fork under the M71m kernel kills every arg-carrying exec in
    # mallocinit and turns the whole shell fleet red with no spec naming the
    # cause (observed #1648: fork runtime files dated Sep 20, M71m merged
    # Sep 21). Cmp each overlay file against the fork's copy -- except the
    # gostalgia/, gostalgia-mods/ and charm-mods/ stage overlays, which are
    # never fork files (only build-gostalgia.sh / build-charmhello.sh consume
    # them; apply.sh §2/§2c excludes them from the copy and deletes leaked
    # copies). Without the same exclusion here they cmp stale on every run
    # and the check can never pass.
    local _repo _fork _f _stale
    _repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || return 0
    [ -d "$_repo/tools/go/overlay" ] || return 0
    # Same fork every build script resolves ("$(dirname "$REPO")/go-virelai");
    # GO_FORK_DIR overrides it exactly like they do.
    _fork="${GO_FORK_DIR:-$(dirname "$_repo")/go-virelai}"
    [ -d "$_fork/src" ] || return 0   # not provisioned yet: the build scripts will
    _stale=""
    for _f in $(cd "$_repo/tools/go/overlay" && find . -type f \
        ! -path "./gostalgia/*" ! -path "./gostalgia-mods/*" \
        ! -path "./charm-mods/*" | sed 's|^\./||'); do
        cmp -s "$_repo/tools/go/overlay/$_f" "$_fork/src/$_f" 2>/dev/null || _stale="$_stale $_f"
    done
    [ -n "$_stale" ] || return 0
    _ENV_OK=0
    env_crit ""
    env_crit "  ✘  go fork overlay drift -- Go ELFs will build against the WRONG runtime."
    env_crit "      fork:   $_fork"
    env_crit "      stale: $_stale"
    env_crit "      fix:    bash tools/go/apply.sh    # re-copy tools/go/overlay/ into the fork"
    env_crit ""
    return 0
}

# ---- the driver --------------------------------------------------------------
env_check_all() {
    _ENV_OK=1; _ENV_RANTED=0
    local bb="${_ENV_HOMEBREW_BIN:-}"
    if [ -z "$bb" ]; then
        bb="$(find_brewbins || true)"
        [ -n "$bb" ] && _ENV_HOMEBREW_BIN="$bb"
    fi

    if [ -n "$bb" ]; then
        # defensively put the Homebrew bin dir FIRST on PATH: a PATH that
        # merely contains it after /bin or /usr/bin still resolves the
        # 2007-era system bash/sed (the exact failure mode this file exists
        # to catch), so dedupe it out and re-prepend.
        local _newpath="" _d _ifs_save="$IFS"
        IFS=":"; for _d in $PATH; do
            [ "$_d" = "$bb" ] && continue
            if [ -n "$_newpath" ]; then _newpath="$_newpath:$_d"; else _newpath="$_d"; fi
        done
        IFS="$_ifs_save"
        PATH="$bb:$_newpath"; export PATH
        # Same second entry CI puts on PATH (.github/workflows/vz-gates.yml
        # and ci.yml "Put Homebrew toolchain on PATH"): brew's GNU sed is
        # keg-only and lives in libexec/gnubin, never in the bin dir, so a
        # freshly installed gnu-sed is invisible until this is on PATH too.
        _ENV_GNUBIN="${bb%/bin}/opt/gnu-sed/libexec/gnubin"
        case ":$PATH:" in
            *":$_ENV_GNUBIN:"*) : ;;
            *) [ -d "$_ENV_GNUBIN" ] && { PATH="$_ENV_GNUBIN:$PATH"; export PATH; } ;;
        esac
    else
        env_warn ""
        env_warn "  Homebrew not found (looked at /opt/homebrew/bin, /usr/local/bin, \$BREW_PREFIX)."
        env_warn "  The tool checks below will tell you if that actually bites."
        env_warn ""
    fi

    check_bash
    check_sed
    check_jq
    check_yq
    check_go_overlay

    if [ "$_ENV_OK" = 1 ]; then
        [ "${VERBOSE:-0}" = 1 ] && env_good "env-check: all modern Homebrew tool versions confirmed ✓"
        return 0
    else
        env_crit ""
        env_crit "  ─────────────────────────────────────────────────────────"
        env_crit "   ONE OR MORE CHECKS ABOVE FAILED."
        env_crit "   toolchain: brew install bash gnu-sed jq yq && fix your PATH."
        env_crit "   go fork:   bash tools/go/apply.sh  (re-copy tools/go/overlay/)."
        env_crit "   Then re-source this file."
        env_crit "  ─────────────────────────────────────────────────────────"
        env_crit ""
        return 1
    fi
}

# Only auto-run when sourced as the top-level command (so `bash env-check.sh`
# doesn't double-run; and so sourcing from within another script is opt-in).
case "${BASH_SOURCE[0]}" in
    "$0")
        # executed directly: run the check, exit with the verdict
        env_check_all
        # shellcheck disable=SC2181
        [ $? = 0 ] || exit 1
        exit 0
        ;;
    *)
        # sourced: expose the function and run it once now
        env_check_all || true
        ;;
esac