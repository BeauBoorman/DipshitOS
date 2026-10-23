#!/usr/bin/env bash
#
# verify-zc-corpus.sh -- M20 Z4a + Z4b (issues #760 + #761): the corpus
# dual-parity gate. Every fixture under tests/zc-corpus/ (plus the stdz
# library modules it compiles with, user/src/lib/stdz/*.zig) must compile on
# BOTH sides:
#
#   host  : built with HOST zig 0.17 by the Z4b target recipe
#           (tools/build-zc-host.sh: `zig build-exe` against the real
#           user/src/lib/zc.zig shim, -T tools/zc-host-link.ld, full
#           semantic analysis of every fixture body, loader-contract
#           check) into artifacts/zc-host-<case>.elf
#   guest : ZC.BIN compiles the same source(s) in-guest via `strace exec
#           ZC.BIN <srcs...> <out.elf>` and the loader runs the ELF
#
# with pinned behavior per case (exit status, ordered markers, printed
# needles, and byte-exact + sha256 file round trips where the fixture does
# file IO). Z4b adds the dual-RUN: each run case's host-built ELF gets its
# own boot asserting the SAME pins, so behavior is byte-equivalent across
# the two compilers. The dialect boundary and the host link contract live
# in docs/archive/line-of-sight.md — this gate is the mechanical half.
#
# Case model. One corpus "case" is one compile unit — a single fixture or a
# multi-file group that the in-guest compiler sees as one flat namespace
# (Z3a: `zc a.z b.z out.elf`; Z3b's app compiles with the stdz modules).
# Group sources are host-checked CONCATENATED (the flat-namespace analogue;
# no @import between them), and staged under distinct share names in-guest.
#
#   z05  Z0.5 dialect acceptance (trivial exit-72 program)
#   vl6  VL6 GUI consumer — COMPILE-ONLY (win syscalls draw a window; a
#        serial log cannot pin pixels, so run parity is a display-backed
#        concern, not this gate's)
#   snk  the VL6 snake game (4 files) — RUN case: compiles in-guest, then
#        the ELF auto-plays (5 s idle auto-start at 1 s/tick, then steers
#        itself into the right wall) and exits 0 with the ordered needles
#        snake-up → snake-move → snake-over. Headless, sys_win_open is
#        EINVAL (no gpu — the game ignores the return), so rendering is
#        display-backed; the pixel proof is verify-live-snake.sh
#   z1a  strings: zc.print + zc.write       exit 0, prints two lines
#   z1b  arrays: fill + print + checksum    exit 0, prints A..H
#   z1c  structs: field store + read        exit 0 (2-byte raw print not
#        pinned — too short to needle against boot noise)
#   z1d  pointers: swap/fill/set through ptr params, exit 72, prints ABCD
#   z1e  control depth: for/switch/else     exit 72 (self-checked)
#   z1f  enums: tags + casts + switch       exit 72 (self-checked)
#   z2a  heap: mmap arena file round trip   exit 72, prints heap-ok,
#        OUT.TXT must equal the 5000-B seeded DATA.TXT byte-exact (sha256)
#   z2b  defer + fn pointers                8 markers, ORDERED, exit 72
#   z3a  multi-file pair (2 sources)        3 markers, ORDERED, exit 72
#   z3b  stdz app + glue + 3 lib modules    2 markers, ORDERED, exit 72,
#        OUT.TXT must equal REPORT.EXP byte-exact (sha256)
#   s3   M70c S3 dialect lift (issue #1455): `break` / `continue` in all
#        three loop forms + nested loops + the defer unwind on `break` —
#        10 markers, ORDERED, exit 72. Not a ladder rung: this shrinks the Z4a
#        dialect boundary rather than adding a step to it. Its last marker is
#        "s3-all-ok", not "s3-ok", because the runner echoes "rx-s3-ok" after
#        the exec — a marker that is a substring of that line would be
#        satisfied by the echo alone.
#   big  ONE source file >2048 B (the snake in a single file; the
#        multi-read proof for zc's source arena) — 4 markers, ORDERED,
#        exit 72; every marker string lives past byte 2048 of the source,
#        so a compiler stuck on one 2048-B file_read could not produce
#        them (claim #992)
#
# The exit status is the strong pin on every run case (each fixture
# self-checks its feature and exits 1 on ANY failure); markers/needles add
# serial evidence that the program actually RAN to that exit, and the
# ordered-walk for z2b/z3a/z3b proves marker sequencing byte-exact.
#
# Structure. One case per VZ boot, mirroring verify-live-zc.sh's proven
# race-averse shape: the compile runs under `strace exec` (SCRIPT, forwarded
# after the boot static exit line), the compiled ELF runs as a plain async
# exec (SCRIPT2, forwarded after "zc: successfully compiled in-guest"), and
# the boot passes when the case's exit line appears (--script-expect). The
# one-traced-task-per-boot shape is what the live gate measured clean (its
# header documents why tracing MAIN.ELF too / packing more per boot flakes
# the exit-report drain). vl6's compile-only case uses the compile line
# itself as --script-expect and never execs its ELF.
#
# Usage:
#   bash tools/verify-zc-corpus.sh            # full class-B: build + every case
#   bash tools/verify-zc-corpus.sh --host     # class-A only: host ELF builds
#   CASES="z2b z3b" bash tools/verify-zc-corpus.sh          # subset (class-B)
#   CASES="z2b" bash tools/verify-zc-corpus.sh --host z1a    # subset (--host)
#   VIRELAI_GATE_SUFFIX=_alt bash tools/verify-zc-corpus.sh  # parallel instance
#
# Evidence: artifacts/m20-zc-corpus.txt (gate log), artifacts/zc-corpus-
# report.txt (per-leg verdicts), artifacts/zc-corpus-<case>-serial.log /
# -run.txt / -out.txt per case, artifacts/zc-host-<case>.elf (the host
# images the dual-run executes in-guest).
#
# Wired into the zc verification path: verify-live-zc.sh delegates its
# host compile-check phase here (--host), so the corpus case table is the
# single source of truth for "every fixture is valid Zig 0.17" — now
# strict-valid, since the Z4b build analyzes every function body.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOST_ONLY=0
CASE_FILTER=""
for a in "$@"; do
    case "$a" in
        --host) HOST_ONLY=1 ;;
        -h|--help) grep -E '^#   (bash|CASES|VIRELAI)' "$0" | sed 's/^#   //'; exit 0 ;;
        *) CASE_FILTER="$CASE_FILTER $a" ;;
    esac
done
[ -n "${CASES:-}" ] && CASE_FILTER="$CASE_FILTER $CASES"
# Locale policy: anything whose ORDER or NAME reaches a comparison, a gate
# line or an artifact name is pinned to C (collation and the [:lower:]/[:upper:]
# tables are locale-dependent; see docs/testing.md "Locale determinism").
CASE_FILTER="$(echo $CASE_FILTER | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | tr '\n' ' ')" # dedupe

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

# --- the corpus table -------------------------------------------------------
# case_def <name> echoes one line:
#   name|kind(run|compile)|exit|ordered-markers(space-sep)|needles(|-sep)
# case_sources <name> echoes "SHARE-NAME repo/path" lines (share order =
#   in-guest argv order; main first, like the live gate).

case_def() {
    case "$1" in
        z05) echo "z05|run|72||" ;;
        vl6) echo "vl6|compile|||" ;;
        snk) echo "snk|run|72|snake-up snake-wait snake-move snake-over|snake-up|snake-wait|snake-move|snake-over" ;;
        z1a) echo "z1a|run|0||Hello from zc strings!|Second line" ;;
        z1b) echo "z1b|run|0||ABCDEFGH" ;;
        z1c) echo "z1c|run|0||" ;;
        z1d) echo "z1d|run|72||ABCD" ;;
        z1e) echo "z1e|run|72||" ;;
        z1f) echo "z1f|run|72||" ;;
        z2a) echo "z2a|run|72||heap-ok" ;;
        z2b) echo "z2b|run|72|z2b-start z2b-fnptr-ok z2b-in-if z2b-defer-if z2b-after-if z2b-defer-a z2b-defer-b z2b-ret-ok|" ;;
        z3a) echo "z3a|run|72|z3a-start z3a-cross-ok z3a-lib-ok|" ;;
        z3b) echo "z3b|run|72|z3b-start z3b-ok|" ;;
        s3) echo "s3|run|72|s3-start s3-while-break s3-while-continue s3-range-break s3-range-continue s3-array-continue s3-nested-break s3-defer-break s3-loop-exit s3-all-ok|" ;;
        big) echo "big|run|72|snake-up snake-wait snake-move snake-over|snake-up|snake-wait|snake-move|snake-over" ;;
        *) echo "" ;;
    esac
}

case_sources() {
    case "$1" in
        z05) echo "Z05.Z tests/zc-corpus/z05-dialect.z" ;;
        vl6) echo "VL6.Z tests/zc-corpus/vl6-gui.z" ;;
        snk) echo "SNAKE.Z tests/zc-corpus/snake-main.z"; echo "SLIB.Z tests/zc-corpus/snake-lib.z"; echo "EV.Z tests/zc-corpus/snake-events.z"; echo "FOOD.Z tests/zc-corpus/snake-food.z" ;;
        z1a) echo "Z1A.Z tests/zc-corpus/z1a-strings.z" ;;
        z1b) echo "Z1B.Z tests/zc-corpus/z1b-arrays.z" ;;
        z1c) echo "Z1C.Z tests/zc-corpus/z1c-structs.z" ;;
        z1d) echo "Z1D.Z tests/zc-corpus/z1d-pointers.z" ;;
        z1e) echo "Z1E.Z tests/zc-corpus/z1e-control.z" ;;
        z1f) echo "Z1F.Z tests/zc-corpus/z1f-enums.z" ;;
        z2a) echo "Z2A.Z tests/zc-corpus/z2a-heap.z" ;;
        z2b) echo "Z2B.Z tests/zc-corpus/z2b-defer-fnptr.z" ;;
        z3a) echo "Z3AM.Z tests/zc-corpus/z3a-multifile.z"; echo "Z3AL.Z tests/zc-corpus/z3a-lib.z" ;;
        z3b) echo "APP.Z tests/zc-corpus/z3b-stdz.z"; echo "LABELS.Z tests/zc-corpus/z3b-labels.z"; echo "FMT.Z user/src/lib/stdz/fmt.zig"; echo "BUILDER.Z user/src/lib/stdz/string_builder.zig"; echo "RING.Z user/src/lib/stdz/ring.zig" ;;
        s3) echo "S3.Z tests/zc-corpus/s3-break.z" ;;
        big) echo "BIG.Z tests/zc-corpus/big-snake.z" ;;
    esac
}

ALL_CASES="$(for c in z05 vl6 z1a z1b z1c z1d z1e z1f z2a z2b z3a z3b s3 snk big; do echo "$c"; done)"

# Which cases to run: all, or the CASES/argv filter (validated against the table).
cases_selected() {
    if [ -z "$CASE_FILTER" ]; then
        echo "$ALL_CASES"
        return 0
    fi
    local out="" c=""
    for c in $CASE_FILTER; do
        if [ -z "$(case_def "$c")" ]; then
            echo "verify-zc-corpus: unknown case '$c' (known: $(echo $ALL_CASES | tr '\n' ' '))" >&2
            return 1
        fi
        out="$out $c"
    done
    echo $out
}

# Validate the filter once at startup; SELECTED drives every phase.
SELECTED="$(cases_selected)"
[ -n "$SELECTED" ] || { echo "verify-zc-corpus: no cases selected" >&2; exit 1; }    # Host-side phase (Z4a + Z4b): every selected case's sources are built by
# HOST zig 0.17 with the Z4b target recipe — tools/build-zc-host.sh, which
# concatenates the sources with a `_start` epilogue, runs `zig build-exe`
# (-fno-entry, custom -T script, 4 KiB pages, ReleaseSmall, stripped), and
# validates the image against the kernel loader contract
# (tools/check-zc-host-contract.py). This is strictly STRONGER than the
# Z4a-era `zig build-obj` check: build-obj only lazily analyzes unreferenced
# functions, so a fixture whose `main` body used e.g. `i += 1` or implicit
# u64->u8 stores passed; build-exe with the epilogue forces FULL semantic
# analysis of every fixture body. The emitted ELF (artifacts/zc-host-<case>.
# elf) is ALSO the host side of the dual-run: the class-B host boot execs it
# in-guest and asserts byte-equivalent behavior against the zc-compiled run.
# Every source must stay under the in-guest source-arena cap (32768 B —
# zc's shared arena; run() drains each source with chunked file_reads until
# EOF, so the old 2048-B single-read cap no longer truncates large sources;
# see user/src/zc.zig source_arena_cap, claim #992).
# Used standalone (--host), by verify-live-zc.sh, and as the fast-fail front
# half of the full class-B run.
host_check() {
    local npass=0 nfail=0 total=0
    for name in $(cases_selected); do
        total=$((total + 1))
        # size + existence guard (sources larger than the shared arena would
        # overflow it in-guest; run() fails loudly, never truncates)
        local ok=1 paths=""
        while read -r _ path; do
            if [ ! -f "$path" ]; then
                echo "$name: MISSING source $path" >&2
                ok=0
            elif [ "$(wc -c < "$path" | tr -d ' ')" -gt 32768 ]; then
                echo "$name: source $path is >32768 B (in-guest source-arena cap)" >&2
                ok=0
            fi
            paths="$paths $path"
        done < <(case_sources "$name")
        [ "$ok" = 1 ] || { nfail=$((nfail + 1)); continue; }
        if bash tools/build-zc-host.sh -o "$(art zc-host-$name.elf)" $paths >/dev/null 2>"$(art zc-host-$name.err)"; then
            npass=$((npass + 1))
            echo "host-elf $name: OK — strict zig $(zig version) build + loader-contract check ($(case_sources "$name" | wc -l | tr -d ' ') source(s); $(wc -c < "$(art zc-host-$name.elf)" | tr -d ' ') B image)"
            rm -f "$(art zc-host-$name.err)"
        else
            nfail=$((nfail + 1))
            echo "host-elf $name: FAIL" >&2
            sed 's/^/    /' "$(art zc-host-$name.err)" >&2
        fi
    done
    echo "verify-zc-corpus --host: $npass/$total cases build strict-valid host ELFs under zig $(zig version)"
    [ "$nfail" = 0 ]
}

# --- class-B plumbing (mirrors verify-live-zc.sh) ---------------------------
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
COMPILE_LINE="zc: successfully compiled in-guest"
REAP_LINE="tasks user-exec reaped"

# Seed one case's share: its sources under the case's share names, plus the
# file-IO inputs (DATA.TXT / REPORT.EXP) and their expected sha256.
# Echoes "exp_file exp_sha" when the case has an OUT.TXT pin, else nothing.
seed_case() {
    local name="$1" share="$2"
    # fresh case state on the shared dir
    rm -f "$share"/DATA.TXT "$share"/OUT.TXT "$share"/REPORT.EXP "$share"/*.Z "$share"/*.ELF
    while read -r sname path; do
        cp "$path" "$share/$sname"
        echo "staged $sname ($(wc -c < "$share/$sname" | tr -d ' ') B) from $path"
    done < <(case_sources "$name")
    case "$name" in
        z2a)
            python3 - "$share/DATA.TXT" <<'PY'
import sys
pat = b"the quick brown fox jumps over the lazy dog 0123456789\n"
data = (pat * ((5000 // len(pat)) + 1))[:5000]
assert len(data) == 5000
open(sys.argv[1], "wb").write(data)
PY
            echo "seeded DATA.TXT (5000 B) for the z2a mmap round trip"
            echo "DATA.TXT $(shasum -a 256 "$share/DATA.TXT" | cut -d' ' -f1)"
            ;;
        z3b)
            printf 'hello world\nfoo bar baz\n' > "$share/DATA.TXT"
            printf 'bytes=24\nlines=2\nwords=5\nhex=18\n' > "$share/REPORT.EXP"
            echo "seeded DATA.TXT + REPORT.EXP for the z3b wc app"
            echo "REPORT.EXP $(shasum -a 256 "$share/REPORT.EXP" | cut -d' ' -f1)"
            ;;
    esac
}

# Ordered-presence walk over the serial log (same proof as the live gate):
# first occurrence of each marker must ascend.
markers_ordered() {
    local ser="$1"; shift
    python3 - "$ser" "$@" <<'PY' 2>/dev/null
import sys
path = sys.argv[1]
names = sys.argv[2:]
data = open(path, "rb").read()
last = -1
for name in names:
    idx = data.find(name.encode())
    if idx < 0 or idx < last:
        sys.exit(1)
    last = idx
sys.exit(0)
PY
}

run_one() {
    local name="$1"
    local desc kind exit_code ordered needles
    IFS='|' read -r _ kind exit_code ordered needles <<< "$(case_def "$name")"
    local outname
    outname="$(printf '%s' "$name" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
    local outelf="$outname.ELF"
    local run_log="$(art zc-corpus-$name-run.txt)"
    local serial_copy="$(art zc-corpus-$name-serial.log)"
    local ser="$RUN_DIR/vm-serial-$name.log"
    rm -f "$RUN_DIR/efi-vars.bin" "$ser"

    local compile_line=""
    while read -r sname _; do
        compile_line="$compile_line $sname"
    done < <(case_sources "$name")
    local script="$RUN_DIR/script-$name.txt"
    local script2="$RUN_DIR/script2-$name.txt"
    printf 'ls\nstrace exec ZC.BIN %s %s\n' "$compile_line" "$outelf" > "$script"

    local exp_line=""
    if [ "$kind" = "run" ]; then
        exp_line="tasks user-exec exited status=$exit_code"
        printf 'ls\nexec %s\necho rx-%s-ok\n' "$outelf" "$name" > "$script2"
    else
        exp_line="$COMPILE_LINE"
    fi

    local -a extra=()
    if [ "$kind" = "run" ]; then
        extra=(--script2 "$script2" --script2-after "$COMPILE_LINE")
    fi
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$ser" \
        --script "$script" --script-after "$STATIC_EXIT_LINE" \
        "${extra[@]}" \
        --script-expect "$exp_line" --script-expect-tail 2 --timeout 90 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$ser" ] && cp "$ser" "$serial_copy" || true
    local SER="$serial_copy"

    local banner=0 compiled=0 srcs_ok=0 needles_ok=0 markers_ok=0 ordered=0
    local exit_ok=0 reaped=0 echo_ok=0 loaded=0 fatal=0 out_pin=0
    local srcs_total=0 srcs_seen=0
    if [ -f "$SER" ]; then
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFxc -- "$COMPILE_LINE" "$SER" || true)" = 1 ] && compiled=1
        while read -r sname _; do
            srcs_total=$((srcs_total + 1))
            [ "$(grep -aFc -- "$sname" "$SER" || true)" -ge 1 ] && srcs_seen=$((srcs_seen + 1))
        done < <(case_sources "$name")
        [ "$srcs_seen" = "$srcs_total" ] && [ "$srcs_total" -ge 1 ] && srcs_ok=1
        if [ "$kind" = "run" ]; then
            # load line carries hex suffixes (size=/entry=/stack=/head=), so
            # a plain substring count (no -x) — same as verify-live-zc.sh.
            [ "$(grep -aFc -- "exec: loaded $outelf size=" "$SER" || true)" = 1 ] && loaded=1
            [ "$(grep -aFxc -- "$exp_line" "$SER" || true)" -ge 1 ] && exit_ok=1
            [ "$(grep -aFc -- "$REAP_LINE" "$SER" || true)" -ge 1 ] && reaped=1
            [ "$(grep -aFxc -- "rx-$name-ok" "$SER" || true)" = 1 ] && echo_ok=1
        fi
        local want=0 got=0 n=""
        for n in $(echo "$needles" | tr '|' ' '); do
            [ -z "$n" ] && continue
            want=$((want + 1))
            [ "$(grep -aFc -- "$n" "$SER" || true)" -ge 1 ] && got=$((got + 1))
        done
        [ "$want" = "$got" ] && [ "$want" -ge 0 ] && needles_ok=1
        local nwant=0 n=""
        for n in $ordered; do nwant=$((nwant + 1)); done
        if [ "$nwant" -ge 1 ]; then
            local present=0 m=""
            for m in $ordered; do
                [ "$(grep -aFc -- "$m" "$SER" || true)" -ge 1 ] && present=$((present + 1))
            done
            [ "$present" = "$nwant" ] && markers_ok=1
            markers_ordered "$SER" $ordered && ordered=1
        else
            markers_ok=1; ordered=1
        fi
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi

    # file pin: guest OUT.TXT must equal the host-seeded expectation byte-
    # exact AND sha256-exact. Evidence copy first (gate_end may delete).
    local exp_sha="-" got_sha="-"
    case "$name" in
        z2a) exp_sha="$(shasum -a 256 "$SHARE/DATA.TXT" | cut -d' ' -f1)" ;;
        z3b) exp_sha="$(shasum -a 256 "$SHARE/REPORT.EXP" | cut -d' ' -f1)" ;;
    esac
    if [ "$exp_sha" != "-" ]; then
        if [ -f "$SHARE/OUT.TXT" ]; then
            cp -f "$SHARE/OUT.TXT" "$(art zc-corpus-$name-out.txt)"
            got_sha="$(shasum -a 256 "$SHARE/OUT.TXT" | cut -d' ' -f1)"
            [ "$got_sha" = "$exp_sha" ] && out_pin=1
        fi
    else
        out_pin=1 # no file pin on this case
    fi

    local pass=0
    if [ "$kind" = "run" ]; then
        [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$compiled" = 1 ] && [ "$srcs_ok" = 1 ] && \
            [ "$loaded" = 1 ] && [ "$exit_ok" = 1 ] && [ "$reaped" = 1 ] && [ "$echo_ok" = 1 ] && \
            [ "$needles_ok" = 1 ] && [ "$markers_ok" = 1 ] && [ "$ordered" = 1 ] && \
            [ "$out_pin" = 1 ] && [ "$fatal" = 0 ] && pass=1
    else
        # compile-only: everything except exec/exit/reap/echo; and the ELF
        # must NOT have been exec'd (there is no second script phase).
        local noexec=1
        if [ -f "$SER" ]; then
            [ "$(grep -aFc -- "exec: loaded $outelf size=" "$SER" || true)" = 0 ] || noexec=0
        fi
        [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$compiled" = 1 ] && [ "$srcs_ok" = 1 ] && \
            [ "$needles_ok" = 1 ] && [ "$fatal" = 0 ] && [ "$noexec" = 1 ] && pass=1
    fi

    echo "$name: kind=$kind runner-rc=$rc banner=$banner compiled=$compiled srcs=$srcs_seen/$srcs_total needles=$needles_ok markers=$markers_ok ordered=$ordered loaded=$loaded exit=$exit_ok reaped=$reaped echo=$echo_ok out-sha256=$got_sha (exp $exp_sha) out_pin=$out_pin fatal=$fatal -> $([ "$pass" = 1 ] && echo PASS || echo FAIL)" | tee -a "$REPORT"
    [ "$pass" = 1 ]
}

# Z4b (issue #761) host-boot leg of the dual-run. The host-built ELF
# (artifacts/zc-host-<name>.elf, produced by host_check via
# tools/build-zc-host.sh) is exec'd in its own boot with the SAME behavior
# pins as the zc-compiled run: exit status, needles, ordered markers, and
# the byte-exact + sha256 file pins. Byte-equivalent behavior = the two
# boots' assertion sets agree. No in-guest compile happens (the ELF was
# built host-side); OUT.TXT is removed first so each run creates it fresh
# (file_open CREATE|WRITE semantics are not truncate-on-open).
run_one_host() {
    local name="$1"
    local kind exit_code ordered needles
    IFS='|' read -r _ kind exit_code ordered needles <<< "$(case_def "$name")"
    [ "$kind" = "run" ] || return 1
    local outname
    outname="$(printf '%s' "$name" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
    local hostelf="${outname}H.ELF"
    local host_image="$(art zc-host-$name.elf)"
    [ -f "$host_image" ] || { echo "$name-host: MISSING host ELF $host_image (host_check phase failed?)" >&2; return 1; }
    local run_log="$(art zc-corpus-$name-host-run.txt)"
    local serial_copy="$(art zc-corpus-$name-host-serial.log)"
    local ser="$RUN_DIR/vm-serial-$name-host.log"
    rm -f "$RUN_DIR/efi-vars.bin" "$ser" "$SHARE/OUT.TXT"
    cp "$host_image" "$SHARE/$hostelf"

    local script="$RUN_DIR/script-$name-host.txt"
    printf 'ls\nexec %s\necho rx-%s-h-ok\n' "$hostelf" "$name" > "$script"
    local exp_line="tasks user-exec exited status=$exit_code"

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$ser" \
        --script "$script" --script-after "$STATIC_EXIT_LINE" \
        --script-expect "$exp_line" --script-expect-tail 2 --timeout 90 > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$ser" ] && cp "$ser" "$serial_copy" || true
    local SER="$serial_copy"

    local banner=0 needles_ok=0 markers_ok=0 ordered=0 loaded=0
    local exit_ok=0 reaped=0 echo_ok=0 fatal=0 out_pin=0
    if [ -f "$SER" ]; then
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFc -- "exec: loaded $hostelf size=" "$SER" || true)" = 1 ] && loaded=1
        [ "$(grep -aFxc -- "$exp_line" "$SER" || true)" -ge 1 ] && exit_ok=1
        [ "$(grep -aFc -- "$REAP_LINE" "$SER" || true)" -ge 1 ] && reaped=1
        [ "$(grep -aFxc -- "rx-$name-h-ok" "$SER" || true)" = 1 ] && echo_ok=1
        local want=0 got=0 n=""
        for n in $(echo "$needles" | tr '|' ' '); do
            [ -z "$n" ] && continue
            want=$((want + 1))
            [ "$(grep -aFc -- "$n" "$SER" || true)" -ge 1 ] && got=$((got + 1))
        done
        [ "$want" = "$got" ] && needles_ok=1
        local nwant=0 m=""
        for m in $ordered; do nwant=$((nwant + 1)); done
        if [ "$nwant" -ge 1 ]; then
            local present=0
            for m in $ordered; do
                [ "$(grep -aFc -- "$m" "$SER" || true)" -ge 1 ] && present=$((present + 1))
            done
            [ "$present" = "$nwant" ] && markers_ok=1
            markers_ordered "$SER" $ordered && ordered=1
        else
            markers_ok=1; ordered=1
        fi
        grep -qF -- "[EXC] parking:" "$SER" && fatal=1 || true
    fi

    # File pin: the HOST run must produce the same byte-exact output as the
    # zc run (both equal the host-seeded expectation).
    local exp_sha="-" got_sha="-"
    case "$name" in
        z2a) exp_sha="$(shasum -a 256 "$SHARE/DATA.TXT" | cut -d' ' -f1)" ;;
        z3b) exp_sha="$(shasum -a 256 "$SHARE/REPORT.EXP" | cut -d' ' -f1)" ;;
    esac
    if [ "$exp_sha" != "-" ]; then
        if [ -f "$SHARE/OUT.TXT" ]; then
            cp -f "$SHARE/OUT.TXT" "$(art zc-corpus-$name-host-out.txt)"
            got_sha="$(shasum -a 256 "$SHARE/OUT.TXT" | cut -d' ' -f1)"
            [ "$got_sha" = "$exp_sha" ] && out_pin=1
        fi
    else
        out_pin=1
    fi

    local pass=0
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$loaded" = 1 ] && [ "$exit_ok" = 1 ] && \
        [ "$reaped" = 1 ] && [ "$echo_ok" = 1 ] && [ "$needles_ok" = 1 ] && \
        [ "$markers_ok" = 1 ] && [ "$ordered" = 1 ] && [ "$out_pin" = 1 ] && [ "$fatal" = 0 ] && pass=1

    echo "$name-host: runner-rc=$rc banner=$banner loaded=$loaded exit=$exit_ok reaped=$reaped echo=$echo_ok needles=$needles_ok markers=$markers_ok ordered=$ordered out-sha256=$got_sha (exp $exp_sha) out_pin=$out_pin fatal=$fatal -> $([ "$pass" = 1 ] && echo PASS || echo FAIL)" | tee -a "$REPORT"
    [ "$pass" = 1 ]
}

# --- main --------------------------------------------------------------------
if [ "$HOST_ONLY" = 1 ]; then
    host_check
    exit $?
fi

source tools/lib/gate-run.sh
GATE_LOG="$(art m20-zc-corpus.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art zc-corpus-report.txt)"

echo "=== verify-zc-corpus: M20 Z4a/Z4b — corpus dual parity (host zig 0.17 build + run vs in-guest zc), cases: $(echo $SELECTED | tr '\n' ' ') ==="
zig version
swift --version 2>&1 | head -1
sw_vers
echo "revision: $(git rev-parse HEAD 2>/dev/null || echo unknown) branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown) dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

# Host side first (fast fail before the heavy builds/boots): every selected
# case builds a strict-valid host ELF (full semantic analysis + loader
# contract) into artifacts/zc-host-<case>.elf. Those ELFs are the host half
# of the dual-run — the class-B host boot execs each one in-guest.
if ! host_check; then
    echo "verify-zc-corpus: host build phase FAILED — aborting before class-B" >&2
    exit 1
fi

zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

gate_begin zc-corpus
gate_arm_share
cp zig-out/bin/ZC.BIN "$SHARE/ZC.BIN"
echo "run dir: $RUN_DIR (share seeded with ZC.BIN only)"

: > "$REPORT"
{
    echo "VIRELAIOS zc corpus dual-parity gate (M20 Z4a #760 + Z4b #761)"
    echo "revision: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

nfail=0
ntotal=0
ndual=0
for name in $SELECTED; do
    ntotal=$((ntotal + 1))
    echo
    echo "=== corpus case $name ($ntotal) ==="
    seed_case "$name" "$SHARE"
    if ! run_one "$name"; then
        nfail=$((nfail + 1))
    fi
    # Z4b dual-run: the host-built ELF gets its own boot with the same
    # behavior pins (run cases only; vl6's run parity stays display-backed).
    if [ "$(case_def "$name" | cut -d'|' -f2)" = "run" ]; then
        ndual=$((ndual + 1))
        if ! run_one_host "$name"; then
            nfail=$((nfail + 1))
        fi
    fi
done

echo
echo "=== result ==="
if [ "$nfail" = 0 ]; then
    echo "verify-zc-corpus: PASS — every corpus case built strict-valid with host zig $(zig version) (host link contract, tools/build-zc-host.sh) AND compiled+run in-guest with ZC.BIN, with $ndual dual-run cases asserting byte-equivalent behavior (exit statuses, ordered markers, needles, byte-exact + sha256 file pins) between the host zig ELF and the zc ELF32; vl6 compile-only, run parity display-backed. See $REPORT."
    echo "PASS: $ntotal/$ntotal cases, $ndual dual-run" >> "$REPORT"
    exit 0
fi
echo "verify-zc-corpus: FAILED — $nfail/$ntotal leg(s) failed; see $REPORT and per-case logs."
echo "FAIL: $((ntotal - nfail))/$ntotal" >> "$REPORT"
exit 1
