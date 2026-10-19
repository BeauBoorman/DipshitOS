#!/usr/bin/env bash
#
# inventory-gates.sh -- regenerate (or --check) the machine-generated gate
# fleet inventory (M40 GF1, issue #934; fleet section M40 GF5, issue #940).
#
# Every executable script directly under tools/ gets one row: line count,
# class (A/B/C/D/tooling -- explicit exceptions below, prefix defaults
# otherwise), registration status (just recipe? in the spec-dir class-B
# fleet? named in a workflow, directly or through a `just` recipe the
# workflow delegates to? status.md row?), and a one-line purpose scraped
# from its own header comment. A gate-class script registered nowhere is
# listed as an ORPHAN. Since GF5 the class-B fleet itself is discovered from
# tools/gate/specs/ via tools/gate/fleet.sh and rendered as its own
# section -- the same list `just verify-vz` consumes on Apple silicon.
#
# Usage:
#   bash tools/inventory-gates.sh          # rewrite docs/gate-fleet-inventory.md
#   bash tools/inventory-gates.sh --check  # spec-order + locale invariance.
#                                          # Does NOT fail when the tracked
#                                          # snapshot drifts: requiring every
#                                          # spec PR to commit this file made
#                                          # parallel PRs conflict on a
#                                          # generated table. The fleet source
#                                          # of truth is tools/gate/fleet.sh.
#   just inventory-gates [--check]
#
# Deterministic by construction: no dates, no revisions, no host state, and
# -- since issue #1177 -- a LOCALE PIN, so a fresh render on a clean tree is
# byte-identical in every environment.
#
# --check also runs the spec-shape guard (claim #1193) over
# tools/gate/specs/*.spec: see check_spec_order below.
#
# Locale pin (issue #1177): the render used to depend on the ambient locale.
# `cut -c1-100` counts BYTES under LC_ALL=C (the common macOS shell default
# for scripts) but CHARACTERS under a UTF-8 locale, so a header containing a
# non-ASCII character -- e.g. live-m21-persist-title-orphan.spec's em dash --
# rendered differently in the two environments: `--check` failed for whoever
# was not in the same locale as the author, and `[[:space:]]` in the trailing
# sed was locale-sensitive too. LC_ALL=C is now pinned for the whole render
# (byte-deterministic sorting/comparison), and header truncation is done by
# `truncate_chars` in UTF-8 CHARACTERS rather than bytes -- byte truncation
# can also split a multi-byte sequence and write invalid UTF-8 into a tracked
# markdown file. `--check` additionally asserts render equality across two
# locales, so a future locale-sensitive operation cannot creep back in.
#
set -euo pipefail

export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPORT="docs/gate-fleet-inventory.md"
CHECK=0
[ "${1:-}" = "--check" ] || true
if [ "${1:-}" = "--check" ]; then CHECK=1; fi

class_of() {
    case "$1" in
        # Class C (interactive) -- gate-inventory.md non-gate registers.
        verify-pointer-manual.sh) echo "C"; return ;;
        # Class D (diagnostics, not gates).
        verify-preexit-tx.sh|verify-tx-diag.sh) echo "D"; return ;;
        # Class B without the verify-live- prefix.
        verify-bad-handoff.sh|verify-marker.sh|verify-nvram-console.sh|\
        verify-host-console.sh|verify-zc-corpus.sh) echo "B"; return ;;
        # Class A without the live prefix (portable / CI).
        verify-transcript.sh|verify-unit-tests.sh|verify-mmu-debt.sh|\
        verify-bss-budget.sh|verify-mutations.sh|verify-glyph-raster.sh|\
        verify-ttf-fonts.sh|verify-vf-class-a.sh|check-zc-host-contract.py) echo "A"; return ;;
        verify-live-*.sh) echo "B"; return ;;
        verify-*.sh) echo "A"; return ;;
        *) echo "tooling"; return ;;
    esac
}

# truncate_chars N -- copy stdin to stdout, keeping at most N UTF-8
# CHARACTERS (not bytes). Explicit and locale-proof: python3 decodes UTF-8
# itself, so neither the ambient locale nor a split multi-byte sequence can
# change the result. Readers/writers are the raw byte streams on purpose --
# python's text mode would pick up the very locale we are pinning away from.
truncate_chars() {
    python3 -c '
import sys
limit = int(sys.argv[1])
text = sys.stdin.buffer.read().decode("utf-8", "replace")
sys.stdout.buffer.write(text[:limit].encode("utf-8"))
' "$1"
}

# First "# text" header line (or """docstring opener for .py) in the
# first 12 lines; truncated, pipe-escaped for the markdown table.
purpose_of() {
    awk 'NR<=12 {
        if ($0 ~ /^# [^ ]/) { sub(/^# /, ""); print; exit }
        if ($0 ~ /^"""/) { sub(/^"""/, ""); print; exit }
    }' "$1" | truncate_chars 110 | sed 's/|/\\|/g; s/[[:space:]]*$//'
}

has_just() {
    local name="${1%.sh}"
    name="${name%.py}"
    grep -q "^${name}:" justfile 2>/dev/null
}

# check_spec_order -- spec-shape guard (claim #1193).
#
# `exec` LOADS a program and SPAWNS it, then returns: it does not wait for the
# program to run, let alone finish. A boot script that launches a program while
# an earlier one is still starting has therefore lost whatever ordering it
# assumed, even though the serial log looks interleaved-but-complete. That
# landed as a real bug in live-oliver (#1188): `exec OLIVER.BIN`, then a
# `vf rm` in the same script, raced the first program's write and the gate
# reported the file as missing.
#
# The two mechanically detectable shapes are checked here:
#
#   ungated-echo-end    the run's `--script-expect` marker is one the SCRIPT
#                       supplies, and no stage gate anchors the run on guest
#                       output (`--script-after` / `--script2-after` /
#                       `--script3-after` / `--input-string-after` with at
#                       least one marker no script in the run supplies). The
#                       runner stops the VM on that echo, so a program launched
#                       by the same script can still be coming up while
#                       assertions are evaluated.
#   file-op-after-exec  a `vf <verb>` file-channel operation follows an `exec`
#                       in the same script, so it can race that program's own
#                       writes (the #1188 shape exactly).
#
# A spec may state why such a shape is safe in its header:
#
#   # exec-order: <class> -- <reason>
#
# with <class> one of:
#   intentional      the author vouches for the ordering and says why -- the
#                    bucket for a provable case the parser cannot see, e.g. an
#                    exec whose binary does not exist, so the refusal is
#                    synchronous and no program is ever running
#   self-sequenced   the script itself blocks on the program (`fg N`, the
#                    only blocking job verb the guest shell has), so the echo
#                    cannot precede the program's completion
#   timeout-ordered  the run is bounded by --timeout and its asserts are
#                    order-independent (they need no program output at all)
#   assert-proven    the run ends on a script echo, but its asserts read
#                    output only the program produces, so the stop trigger
#                    is not what makes the run green -- a program that never
#                    ran still fails the run (this shape can flake late; it
#                    cannot pass unproven)
#
# The class must be one of those four (a typo cannot silently exempt a spec),
# and declared exemptions are printed so they stay visible in CI output.
#
# check_spec_order [DIR] -- DIR defaults to tools/gate/specs. The --check
# self-test points it at tools/gate/fixtures/exec-order/{fail,pass} to prove
# the guard still catches the shapes it exists for, and that the declarations
# still clear them.
check_spec_order() {
    local spec_dir="${1:-$ROOT/tools/gate/specs}"
    python3 - "$ROOT" "$spec_dir" <<'PY'
import os
import re
import sys

root = sys.argv[1]
spec_dir = sys.argv[2]

FILE_RE = re.compile(r"^vgate_file\s+(\S+)\s+<<'([A-Z]+)'\s*$")
RUN_RE = re.compile(r"^vgate_run\s+(\S+)\s+--\s*(.*)$")
DECL_RE = re.compile(r"^#\s*exec-order:\s*(\S+)\s*--\s*(\S.*)$")
VF_RE = re.compile(
    r"^\s*vf\s+(ls|cat|rm|mv|mkdir|clone|open|close|write|truncate|fsync)\b")
EXEC_RE = re.compile(r"^\s*(?:strace\s+)?exec\s")

CLASSES = ("intentional", "self-sequenced", "timeout-ordered", "assert-proven")
# A stage gate is any flag that holds the run until the GUEST prints a marker;
# `--script-expect` is deliberately not one: it ENDS the run.
STAGE_FLAGS = ("--script-after", "--script2-after", "--script3-after",
               "--input-string-after")
STAGE_HINT = "/".join(STAGE_FLAGS)


def scan(path):
    """(heredoc bodies by name, logical vgate_run lines) from one spec."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read().split("\n")
    bodies = {}
    runs = []
    decls = []
    i = 0
    pending = ""
    while i < len(raw):
        line = raw[i]
        m = FILE_RE.match(line)
        if m:
            name, term = m.group(1), m.group(2)
            body = []
            i += 1
            while i < len(raw) and raw[i].strip() != term:
                body.append(raw[i])
                i += 1
            bodies[name] = body
            i += 1
            continue
        # Long vgate_run lines are continued with a trailing backslash, so
        # join logical lines outside heredocs before matching a run.
        if line.rstrip().endswith("\\"):
            pending += line.rstrip()[:-1]
        else:
            logical = pending + line
            pending = ""
            r = RUN_RE.match(logical)
            if r:
                runs.append((r.group(1), r.group(2)))
            d = DECL_RE.match(line)
            if d:
                decls.append((d.group(1), d.group(2)))
        i += 1
    return bodies, runs, decls


def quote_arg(flags, name):
    """Values of FLAG in any of the three spellings the fleet uses: 'single
    quoted', "double quoted", or a bare single token. (Requiring one quote
    style silently misses the other -- and the miss is invisible, since a
    missing marker looks like a spec that has none.)"""
    pat = re.compile(re.escape(name) + r"\s+(?:'([^']*)'|\"([^\"]*)\"|(\S+))")
    return [a or b or c for a, b, c in pat.findall(flags)]


def has_exec(body):
    return any(EXEC_RE.match(line) for line in body)


def script_names(flags):
    """Names of the vgate_file scripts the run forwards. `--script[23]?`
    deliberately excludes --script-expect / --script-after / --script-delay,
    and the quote is optional for the same reason as in quote_arg."""
    return re.findall(r"--script[23]?\s+(?:'|\")?\$RUN_DIR/([A-Za-z0-9_.-]+)", flags)


def script_produces(body, marker):
    """True when MARKER can reach the serial because the SCRIPT puts it
    there. The console echoes every command line the shell runs (observed: a
    serial log carries the `exec OLIVER.BIN ...` line verbatim), so any script
    line containing the marker is script-supplied evidence -- an `echo MARKER`
    line is only the explicit form of the same thing."""
    return any(marker in line for line in body)


def main():
    violations = []
    declared = []
    nspecs = 0
    bad_class = []
    for fname in sorted(os.listdir(spec_dir)):
        if not fname.endswith(".spec"):
            continue
        nspecs += 1
        path = os.path.join(spec_dir, fname)
        bodies, runs, decls = scan(path)
        for word, reason in decls:
            if word not in CLASSES:
                bad_class.append((fname, word))
            else:
                declared.append((fname, word, reason))
        for tag, flags in runs:
            bodies_here = [bodies[s] for s in script_names(flags) if s in bodies]
            # A run that launches no program has no ordering to lose: an
            # echo-ended script is then perfectly safe, and legitimately common.
            if not any(has_exec(b) for b in bodies_here):
                continue
            # A stage gate holds the NEXT script back until a marker appears.
            # That only sequences the run if the marker must come from the
            # GUEST: a gate on a marker the scripts themselves supply fires on
            # the script's own echo and is a delay, not a gate (live-wm3-taskbar
            # gates --script3-after on `taskbar-go`, which its own s2 script
            # echoes). So the excuse holds only when at least one gate marker
            # is one no script in the run supplies.
            stage_markers = [m for f in STAGE_FLAGS for m in quote_arg(flags, f)]
            if any(not any(script_produces(b, m) for b in bodies_here)
                   for m in stage_markers):
                continue
            for marker in quote_arg(flags, "--script-expect"):
                if any(script_produces(b, marker) for b in bodies_here):
                    violations.append((fname, "run %s" % tag,
                        "run %s launches a program but ends on --script-expect "
                        "'%s', which the script itself supplies, and no stage gate "
                        "anchors the run on guest output: the VM stops while that "
                        "program is still starting, so the run can pass without "
                        "proof it ran. End the run on a program marker through a "
                        "stage gate (%s), or declare `# exec-order: <class> -- "
                        "<reason>`." % (tag, marker, STAGE_HINT)))
        for name, body in bodies.items():
            seen_exec = False
            for line in body:
                if EXEC_RE.match(line):
                    seen_exec = True
                elif seen_exec and VF_RE.match(line):
                    violations.append((fname, "script %s" % name,
                        "`%s` follows an exec in the same script: exec returns "
                        "before the program runs, so the file operation can race "
                        "that program's own writes (the #1188 shape). Split it into "
                        "a later staged script, or declare `# exec-order: "
                        "<class> -- <reason>`." % line.strip()))
    declared_files = {d[0]: d[1] for d in declared}
    undeclared = [v for v in violations if v[0] not in declared_files]
    excused = [v for v in violations if v[0] in declared_files]
    print("spec-order: %d spec file(s) in %s; %d declared exemption(s), "
          "%d excused violation(s)"
          % (nspecs, os.path.relpath(spec_dir, root), len(declared), len(excused)))
    for fname, word, reason in declared:
        print("  declared  %-34s %-16s %s" % (fname, word, reason[:60]))
    for fname, where in sorted({(v[0], v[1]) for v in excused}):
        print("  excused   %-34s %s" % (fname, where))
    for fname, word in bad_class:
        print("  FAIL      %-34s declaration class '%s' is not one of %s"
              % (fname, word, "|".join(CLASSES)))
    for fname, where, detail in undeclared:
        print("  VIOLATION %s (%s):\n            %s" % (fname, where, detail))
    if undeclared or bad_class:
        print("spec-order: FAIL -- %d violation(s) need a fix or a declaration"
              % (len(undeclared) + len(bad_class)))
        return 1
    print("spec-order: OK (no ungated echo-ended run, no file op racing an exec)")
    return 0


sys.exit(main())
PY
}

render_to() {
    local out="$1"
    local total=0 orphans=0
    local orphan_list="" rows=""
    local nA=0 nB=0 nC=0 nD=0 nT=0 just_yes=0 flt_yes=0 ci_yes=0 st_yes=0

    # The class-B fleet, discovered from the spec dir (GF5). One
    # "kind<TAB>id" line per member; consumed for the fleet section and
    # the per-script fleet column.
    local fleet_tsv="$(mktemp "${TMPDIR:-/tmp}/fleet-tsv.XXXXXX")"
    bash "$ROOT/tools/gate/fleet.sh" list > "$fleet_tsv"

    # Delegation: a workflow may run `just <recipe>` instead of naming each
    # gate script (ci.yml delegates class A to `just verify-portable`). A
    # script the delegated recipe invokes is as registered as one the
    # workflow names literally -- resolve those recipe bodies once and
    # search them alongside the workflow files below.
    local delegated_recipes="$(grep -hEo '(^|[[:space:]])run:[[:space:]]*just +[A-Za-z_][A-Za-z0-9_-]*' .github/workflows/*.yml 2>/dev/null | grep -Eo 'just +[A-Za-z_][A-Za-z0-9_-]*' | awk '{print $2}' | LC_ALL=C sort -u | tr '\n' ' ' || true)"
    local just_body="$(mktemp "${TMPDIR:-/tmp}/just-body.XXXXXX")"
    if [ -n "$delegated_recipes" ]; then
        awk -v recipes=" $delegated_recipes" '
            /^[A-Za-z_][A-Za-z0-9_-]*:/ {
                name = $1; sub(/:.*$/, "", name)
                insec = (index(recipes, " " name " ") > 0)
                next
            }
            insec && /^[[:space:]]/ { print; next }
            { insec = 0 }
        ' justfile > "$just_body"
    fi

    while IFS= read -r f; do
        base="$(basename "$f")"
        lines="$(wc -l < "$f" | tr -d ' ')"
        cls="$(class_of "$base")"
        total=$((total + 1))
        case "$cls" in
            A) nA=$((nA+1)) ;; B) nB=$((nB+1)) ;; C) nC=$((nC+1)) ;;
            D) nD=$((nD+1)) ;; *) nT=$((nT+1)) ;;
        esac
        if has_just "$base"; then j="y"; just_yes=$((just_yes+1)); else j="n"; fi
        if awk -F'\t' -v id="${base%.sh}" -v py="${base%.py}" \
                '$2==id || $2==py { found=1 } END { exit !found }' "$fleet_tsv"; then
            fl="y"; flt_yes=$((flt_yes+1)); else fl="n"; fi
        if grep -qF "tools/$base" .github/workflows/*.yml 2>/dev/null || grep -qF "tools/$base" "$just_body" 2>/dev/null; then
            c="y"; ci_yes=$((ci_yes+1)); else c="n"; fi
        if grep -qF "$base" docs/status.md 2>/dev/null; then
            s="y"; st_yes=$((st_yes+1)); else s="n"; fi
        pur="$(purpose_of "$f")"
        [ -n "$pur" ] || pur="(no header line)"
        if { [ "$cls" = "A" ] || [ "$cls" = "B" ] || [ "$cls" = "C" ] || [ "$cls" = "D" ]; } \
            && [ "$j" = "n" ] && [ "$fl" = "n" ] && [ "$c" = "n" ] && [ "$s" = "n" ]; then
            orphans=$((orphans+1))
            orphan_list="${orphan_list}${base}"$'\n'
        fi
        rows="${rows}| \`$base\` | $lines | $cls | $j | $fl | $c | $s | $pur |"$'\n'
    done <<EOF
$(LC_ALL=C ls tools/*.sh tools/*.py 2>/dev/null | LC_ALL=C sort)
EOF

    {
        echo "# Gate fleet inventory (generated)"
        echo
        echo "> Machine-generated by \`bash tools/inventory-gates.sh\` (M40 GF1,"
        echo "> issue #934). **Do not hand-edit.** Re-render locally to read it."
        echo "> **Do not commit this file in a spec or script PR** -- parallel"
        echo "> PRs rewrote the same table and GitHub blocked the merge. The"
        echo "> fleet source of truth is \`tools/gate/fleet.sh list\`. \`--check\`"
        echo "> enforces spec-order and locale invariance, not snapshot equality."
        echo "> Subdirectory tooling (\`lib/\`, \`status/\`, \`context/\`,"
        echo "> \`gate/\`) is summarized below, not rowed."
        echo
        echo "## Summary"
        echo
        echo "| metric | count |"
        echo "|---|---|"
        echo "| top-level scripts (\`tools/*.sh\` + \`tools/*.py\`) | $total |"
        echo "| class A (portable / CI) | $nA |"
        echo "| class B (VZ hardware gate) | $nB |"
        echo "| class C (interactive) | $nC |"
        echo "| class D (diagnostic) | $nD |"
        echo "| tooling (not gates) | $nT |"
        echo "| with a just recipe | $just_yes |"
        echo "| in the class-B fleet (spec dir / legacy script) | $flt_yes |"
        echo "| named in a GitHub workflow | $ci_yes |"
        echo "| named in docs/status.md | $st_yes |"
        echo "| **orphans (gate-class, registered nowhere)** | **$orphans** |"
        echo
        echo "## Subdirectory tooling (not gates)"
        echo
        echo "| dir | files | role |"
        echo "|---|---|---|"
        for d in lib status context gate; do
            n="$(find "tools/$d" -type f 2>/dev/null | wc -l | tr -d ' ')"
            case "$d" in
                lib) r="per-run isolation for live gates (\`gate-run.sh\`)" ;;
                status) r="multiagent coordination gate + claim tooling (class A)" ;;
                context) r="context snapshot helpers" ;;
                gate) r="M40 vgate harness + specs (GF2+)" ;;
            esac
            echo "| \`tools/$d/\` | $n | $r |"
        done
        echo
        echo "## Class-B fleet (discovered from the spec dir)"
        echo
        echo "> M40 GF5 (issue #940): this section IS the fleet inventory -- the"
        echo "> exact list \`bash tools/gate/fleet.sh list\` produces, which"
        echo "> \`just verify-vz\` consumes on Apple silicon. A spec added under"
        echo "> tools/gate/specs/ appears here (and in just + CI) with zero list"
        echo "> edits. Do not commit a re-render of this snapshot in that PR."
        echo
        echo "Members: every \`tools/gate/specs/*.spec\` (run through"
        echo "\`tools/gate/vgate.sh\`) plus the four legacy class-B scripts. The"
        echo "interactive serial-takeover gate (\`zig build run\`, needs a TTY) is"
        echo "deliberately not part of the automated fleet. Run one with"
        echo "\`just gate <id>\`, a pattern group with \`just gates <pattern>\`, all"
        echo "of them with \`just verify-vz\`."
        echo
        echo "| kind | id | runs / asserts | spec header |"
        echo "|---|---|---|---|"
        while IFS=$'\t' read -r k id; do
            if [ "$k" = spec ]; then
                spec="$ROOT/tools/gate/specs/$id.spec"
                na="$(grep -c '^vgate_assert ' "$spec" || true)"
                nr="$(grep -c '^vgate_run ' "$spec" || true)"
                hdr="$(grep -m1 '^# ' "$spec" | sed 's/^# //' | truncate_chars 100 | sed 's/|/\\|/g; s/[[:space:]]*$//')"
                [ -n "$hdr" ] || hdr="(no header comment)"
                echo "| spec | \`$id\` | ${nr:-0} run / ${na:-0} assert | $hdr |"
            else
                echo "| script | \`$id\` | (legacy script) | \`tools/$id.sh\` |"
            fi
        done < "$fleet_tsv"
        echo
        echo "## Orphans"
        echo
        if [ "$orphans" -eq 0 ]; then
            echo "None -- every gate-class script is registered somewhere."
        else
            echo "Gate-class scripts with no just recipe, no fleet membership, no"
            echo "workflow mention (direct or through a delegated just recipe), and"
            echo "no status.md row:"
            echo
            printf '%s' "$orphan_list" | sed 's/^/- `/' | sed 's/$/`/'
        fi
        echo
        echo "## All top-level scripts"
        echo
        echo "Columns: \`just\` = justfile recipe of the same name; \`fleet\` = in"
        echo "the spec-dir class-B fleet (\`tools/gate/fleet.sh list\`); \`ci\` ="
        echo "named in \`.github/workflows/*.yml\`, directly or through a \`just\`"
        echo "recipe a workflow delegates to; \`st\` = named in"
        echo "\`docs/status.md\` (\`y\` = yes, \`n\` = no throughout)."
        echo
        echo "| script | lines | class | just | fleet | ci | st | purpose |"
        echo "|---|---|---|---|---|---|---|---|"
        printf '%s' "$rows"
    } > "$out"
    rm -f "${fleet_tsv:-}" "${just_body:-}"
}

if [ "$CHECK" -eq 1 ]; then
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/inv-check.XXXXXX")"
    tmp="$tmpdir/report.md"
    render_to "$tmp"
    rc=0
    if cmp -s "$tmp" "$REPORT"; then
        echo "inventory-gates --check: OK ($REPORT matches a fresh render)"
    else
        echo "inventory-gates --check: NOTE -- $REPORT is a snapshot and drifted from a fresh render."
        echo "Do not commit a re-render in a spec/script PR (that is the recurring GitHub conflict)."
        echo "Source of truth is 'bash tools/gate/fleet.sh list'. Re-render locally with 'just inventory-gates' if you want to read the table."
    fi
    # Locale invariance (issue #1177): the render must be byte-identical when
    # the ambient locale differs. Plain `render_to` already pins LC_ALL=C, so
    # render the second copy with a UTF-8 locale forced for the whole pass --
    # if any operation is still locale-sensitive, the two diverge here instead
    # of in a contributor's shell.
    # NOTE: `locale -a | grep -q ...` is a trap under `set -o pipefail` --
    # grep leaves early on the match, the producer takes SIGPIPE, and the
    # pipeline reports failure, so the probe silently reads "not installed".
    # Feed grep from a here-string (no second process, no pipe to break).
    probe="en_US.UTF-8"
    if grep -qixE 'en_US\.utf-?8' <<< "$(locale -a 2>/dev/null || true)"; then
        ( export LC_ALL="$probe" LC_CTYPE="$probe"; render_to "$tmpdir/report-utf8.md" )
        if cmp -s "$tmp" "$tmpdir/report-utf8.md"; then
            echo "inventory-gates --check: OK (render is locale-invariant: LC_ALL=C == $probe)"
        else
            echo "inventory-gates --check: FAIL -- the render depends on the locale."
            echo "A locale-sensitive operation crept back into render_to; diff (C vs $probe):"
            diff -u "$tmp" "$tmpdir/report-utf8.md" | head -30 || true
            rc=1
        fi
    else
        echo "inventory-gates --check: NOTE -- $probe not installed on this host; " \
             "the two-locale invariance check was skipped (the render is still LC_ALL-pinned)"
    fi
    # Spec-shape guard (claim #1193): `exec` spawns a program and returns, so a
    # boot script that ends a run on its own echo while a program it launched is
    # still starting has lost the ordering it assumed. Pure spec text -- no VM,
    # no host state -- so it is enforced here, on the same class-A path as the
    # registration guard above.
    check_spec_order "$ROOT/tools/gate/specs" || rc=1

    # ...and the guard's own self-test. A rule that quietly stops matching the
    # shape it was written for would keep reporting OK, so the fixtures under
    # tools/gate/fixtures/exec-order/ (never fleet members -- never executed)
    # must still fail on the two bad shapes and still pass once declared.
    order_fixtures="$ROOT/tools/gate/fixtures/exec-order"
    if order_fail_out="$(check_spec_order "$order_fixtures/fail" 2>&1)"; then
        echo "inventory-gates --check: FAIL -- the spec-order guard passed its FAIL fixtures."
        printf '%s\n' "$order_fail_out"
        rc=1
    else
        while IFS='|' read -r fixture needle; do
            if ! grep -qF "$fixture" <<<"$order_fail_out" || \
               ! grep -qF "$needle" <<<"$order_fail_out"; then
                echo "inventory-gates --check: spec-order self-test FAILED -- $fixture no longer trips ('$needle' absent from its output)."
                printf '%s\n' "$order_fail_out"
                rc=1
            fi
        done <<'PAIRS'
ungated-echo-end.spec|no stage gate
exec-then-vf.spec|follows an exec
vacuous-gate.spec|no stage gate
bad-class.spec|declaration class
PAIRS
        if [ "$rc" -eq 0 ]; then
            echo "inventory-gates --check: OK (spec-order self-test: 4 FAIL fixtures still flagged)"
        fi
    fi
    if ! order_pass_out="$(check_spec_order "$order_fixtures/pass" 2>&1)"; then
        echo "inventory-gates --check: FAIL -- the spec-order guard flagged its PASS fixtures " \
             "(a declaration stopped clearing, or the rule over-fires on a launch-free run)."
        printf '%s\n' "$order_pass_out"
        rc=1
    fi

    # warm-census self-test (M131d #2641): fixtures under
    # tools/gate/fixtures/warm-census/ (never fleet members -- never executed).
    # pass/ must render expected.txt byte-for-byte under LC_ALL=C and the
    # probe locale, and every fail/ fixture must trip its named error.
    census_fixtures="$ROOT/tools/gate/fixtures/warm-census"
    census_py="$ROOT/tools/gate/fleet-census.py"
    if census_pass="$(LC_ALL=C python3 "$census_py" --spec-dir "$census_fixtures/pass" 2>&1)" && \
       [ "$census_pass" = "$(cat "$census_fixtures/expected.txt")" ]; then
        census_ok=1
    else
        echo "inventory-gates --check: FAIL -- warm-census pass fixtures no longer render expected.txt"
        printf '%s\n' "$census_pass"
        rc=1
        census_ok=0
    fi
    if [ "$census_ok" -eq 1 ] && \
       grep -qixE 'en_US\.utf-?8' <<< "$(locale -a 2>/dev/null || true)"; then
        census_utf8="$(LC_ALL=en_US.UTF-8 LC_CTYPE=en_US.UTF-8 python3 "$census_py" --spec-dir "$census_fixtures/pass")"
        if [ "$census_utf8" != "$census_pass" ]; then
            echo "inventory-gates --check: FAIL -- warm-census render depends on the locale."
            rc=1
        fi
    fi
    if census_fail_out="$(python3 "$census_py" --spec-dir "$census_fixtures/fail" 2>&1)"; then
        echo "inventory-gates --check: FAIL -- the warm census passed its FAIL fixtures."
        printf '%s\n' "$census_fail_out"
        rc=1
    else
        while IFS='|' read -r fixture needle; do
            if ! grep -qF "$fixture" <<<"$census_fail_out" || \
               ! grep -qF "$needle" <<<"$census_fail_out"; then
                echo "inventory-gates --check: warm-census self-test FAILED -- $fixture no longer trips ('$needle' absent from its output)."
                printf '%s\n' "$census_fail_out"
                rc=1
            fi
        done <<'PAIRS'
bad-class.spec|is not one of a-f
declared-adopted.spec|is adopted
declared-twice.spec|declared twice
malformed-decl.spec|malformed
no-separator.spec|missing -- separator
unknown-leg.spec|names no vgate_run
PAIRS
        if [ "$rc" -eq 0 ]; then
            echo "inventory-gates --check: OK (warm-census self-test: pass fixtures render + 6 FAIL fixtures flagged)"
        fi
    fi

    rm -rf "$tmpdir"
    exit "$rc"

else
    render_to "$REPORT"
    echo "wrote $REPORT"
fi
