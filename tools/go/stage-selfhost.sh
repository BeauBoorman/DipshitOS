#!/usr/bin/env bash
#
# stage-selfhost.sh -- stage everything the GUEST needs to build a Go program
# with its own cmd/compile + cmd/link (M70c-S1T, issue #1543, D4; the package
# surface is M107b, issue #2319).
#
# The pinned program is tools/go/hello.go (issue #1163's phase-0a hello:
# "runtime" only, zero standard-library OS imports, prints "hello from
# virelai" / "virelai-go OK"). Compiling it in the guest needs two things the
# guest cannot produce:
#
#   1. an import config naming the export data for `runtime` (the guest has no
#      go command and no build cache), and
#   2. the package ARCHIVES cmd/link resolves symbols from, because a Go
#      executable is not one object file: main.o references runtime.*, and the
#      linker needs runtime.a's object + every package in its closure.
#
# What gets staged is POLICY, not a fixture's closure: tools/go/pkg-table.txt
# is the reviewable table — `allow` roots are the measured fleet surface plus
# the virelai/vi + virelai/vsys SDK pair, `deny` lines carry the named
# refusals. There is deliberately no /host/GOSRC/ std-from-source tier: the
# guest reads files 2048 B per syscall into 256 MiB, so a package is
# buildable in-guest iff its archive is staged here.
#
# So this stages, into .build/go/selfhost/ (flat — the guest opens share-root
# paths; nested share paths are not proven on this GOOS):
#
#   GOIMPORT.CFG   `packagefile <import path>=/host/GPKG_<name>.a` per package
#   GPKG_*.a       the archives of the allow roots' GOOS=virelai closure
#   GOPKGS.TXT     every importable path marked staged / denied / unstaged —
#                  the driver's dep_unsupported oracle (default /host/GOPKGS.TXT)
#   HELLO.GO       the pinned source, byte-identical to tools/go/hello.go
#
# and the share-copy step is the spec's own setup hook (see
# tools/gate/specs/go-hello.spec runs 06-08).
#
# It also SELF-CHECKS the kernel's argv budget (kernel/src/exec.zig:
# max_exec_args = 8, arg_slot_bytes = 256) against the exact command lines the
# guest runs, so an over-long flag is a failure here rather than a boot cycle
# that dies in `too_many_args`/`no_args_room`.
#
# Usage: bash tools/go/stage-selfhost.sh
#
# HOST PREREQUISITE for the go-hello runs 06-08, same shape as build-go.sh.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
SRC_REL="tools/go/hello.go"
OUT_DIR="$REPO/.build/go/selfhost"
PREFIX="GPKG_"

log() { printf 'stage-selfhost: %s\n' "$*"; }

[ -x "$FORK_DIR/bin/go" ] || {
    log "missing fork toolchain at $FORK_DIR/bin/go"
    log "provision it once with: bash tools/go/apply.sh && just go-toolchain"
    exit 1
}

export GOROOT="$FORK_DIR"
export PATH="$FORK_DIR/bin:$PATH"
export GOTOOLCHAIN=local
export GO111MODULE=off
export CGO_ENABLED=0
export GOOS=virelai
export GOARCH=arm64

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# --- 0. the policy table ------------------------------------------------------
# The allow roots + deny rules come from the checked-in table. An empty table
# here would silently stage nothing and every std import would refuse
# in-guest — fail instead.
TABLE="$REPO/tools/go/pkg-table.txt"
[ -f "$TABLE" ] || { log "missing policy table $TABLE"; exit 1; }
awk '$1 == "allow" { print $2 }' "$TABLE" > "$OUT_DIR/.allow-roots"
[ -s "$OUT_DIR/.allow-roots" ] || {
    log "$TABLE names no allow roots"
    exit 1
}

# virelai/* roots resolve in GOPATH mode through a src/ symlink — the same
# trick build-gobuild.sh uses (`virelai/...` wildcard expansion ignores
# symlinks, so the universe listing below enumerates package dirs instead).
GOPATH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-gopath.XXXXXX")"
trap 'rm -rf "$GOPATH_DIR"' EXIT
mkdir -p "$GOPATH_DIR/src"
ln -sfn "$REPO/user/go" "$GOPATH_DIR/src/virelai"
export GOPATH="$GOPATH_DIR"

# --- 1. the closure -----------------------------------------------------------
# -export makes the go command build (and cache) what is missing, so this
# works on a fork whose std was only ever compiled, never installed to pkg/.
cd "$REPO/tools/go"
# shellcheck disable=SC2046  # allow roots are package paths, word-split on purpose
go list -export -deps -f '{{.ImportPath}}|{{.Export}}' \
    $(cat "$OUT_DIR/.allow-roots") > "$OUT_DIR/.closure"

python3 - "$OUT_DIR" "$PREFIX" "$OUT_DIR/.closure" <<'PY'
import os, re, shutil, sys
out_dir, prefix, list_file = sys.argv[1], sys.argv[2], sys.argv[3]
lines = [l for l in open(list_file).read().splitlines() if l.strip()]
pkgs, seen, indexed = [], {}, []
fallback = 0
for line in lines:
    path, _, export = line.partition("|")
    if not export:
        # `unsafe` has no archive: the compiler knows it intrinsically and the
        # linker never resolves a symbol through it. Not an error.
        if path not in ("unsafe",):
            sys.exit("stage-selfhost: %s has no export data (run `go install "
                     "std`? see tools/go/README.md)" % path)
        continue
    if not os.path.exists(export):
        sys.exit("stage-selfhost: %s export data missing: %s" % (path, export))
    name = prefix + re.sub(r"[^A-Za-z0-9]+", "_", path).strip("_") + ".a"
    # kernel/src/file_table.zig truncates every share name to 31 bytes, so a
    # longer staged name could not be opened by the full path the import
    # config names. Long import paths therefore get an indexed name, and the
    # manifest comment below keeps the share debuggable.
    if len(name) > 31:
        name = "%s%02d.a" % (prefix, fallback)
        fallback += 1
        indexed.append((name, path))
    if name in seen:
        sys.exit("stage-selfhost: %s and %s collide on %s"
                 % (seen[name], path, name))
    seen[name] = path
    shutil.copyfile(export, os.path.join(out_dir, name))
    pkgs.append((path, name, os.path.getsize(export)))
total = sum(p[2] for p in pkgs)
with open(os.path.join(out_dir, "GOIMPORT.CFG"), "w") as cfg:
    cfg.write("# generated by tools/go/stage-selfhost.sh -- do not edit\n")
    for path, name, _ in sorted(pkgs):
        cfg.write("packagefile %s=/host/%s\n" % (path, name))
    # The indexed names are opaque in a serial log; say what they are.
    for name, path in indexed:
        cfg.write("# %s = %s\n" % (name, path))
print("stage-selfhost: %d packages, %.2f MiB of archives"
      % (len(pkgs), total / 1048576.0))
print("stage-selfhost: import config %d lines" % len(pkgs))
PY

cp "$REPO/$SRC_REL" "$OUT_DIR/HELLO.GO"

# --- 1b. GOPKGS.TXT: the per-package disposition table -------------------------
# The driver's dep_unsupported oracle. The universe is every importable path
# under GOOS=virelai: `std` plus the user/go packages an in-guest program
# could name (dirs enumerated on the filesystem — `virelai/...` wildcard
# expansion ignores the symlink above). For each package the table records
# its own name, whether the LIST/BUILD itself failed, and its dep list — the
# generator below turns that into one `staged|denied|unstaged` row per path.
VI_PKGS="$(cd "$REPO/user/go" && find . -name '*.go' ! -name '*_test.go' -print \
    | sed 's|^\./||; s|/[^/]*$||' | grep -v '^\.$' | grep -v '/testdata/' \
    | sort -u | sed 's|^|virelai/|')"
# shellcheck disable=SC2086  # package list, word-split on purpose
go list -export -e \
    -f '{{.ImportPath}}|{{.Name}}|{{if .Error}}ERR{{end}}|{{join .Deps " "}}' \
    std $VI_PKGS > "$OUT_DIR/.universe"

python3 - "$OUT_DIR" "$TABLE" <<'PY'
import sys
out_dir, table_path = sys.argv[1], sys.argv[2]

# --- read the policy table ---------------------------------------------------
# Grammar: `allow <pkg>` | `deny <pattern> <reason...>` | `#` comment. A deny
# pattern ending in '/' is a subtree rule: it matches a package whose import
# path CONTAINS that element (`deny internal/` covers internal/abi and
# crypto/internal/cryptotest alike). Deny rules are policy — they refuse by
# name but do NOT propagate to dependents (fmt is not broken because
# internal/abi is std-private); only a real build failure propagates.
allow, rules = set(), []
for n, raw in enumerate(open(table_path), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split(None, 2)
    if parts[0] == "allow" and len(parts) == 2:
        allow.add(parts[1])
    elif parts[0] == "deny" and len(parts) >= 3:
        pat, reason = parts[1], parts[2]
        rules.append((pat[:-1] if pat.endswith("/") else pat,
                      pat.endswith("/"), reason))
    else:
        sys.exit("%s:%d: not an allow/deny line: %r" % (table_path, n, line))

def deny_reason(path):
    for pat, subtree, reason in rules:
        if (subtree and pat in path.split("/")) or (not subtree and pat == path):
            return reason
    return None

for p in sorted(allow):
    if deny_reason(p):
        sys.exit("%s: %s is both allowed and denied" % (table_path, p))

# --- read what got staged ----------------------------------------------------
staged = set()
for line in open(out_dir + "/GOIMPORT.CFG"):
    if line.startswith("packagefile "):
        staged.add(line.split()[1].split("=", 1)[0])
staged.add("unsafe")  # intrinsic — the compiler knows it, no archive exists

# --- the universe ------------------------------------------------------------
own_err, names, deps = set(), {}, {}
for line in open(out_dir + "/.universe"):
    line = line.rstrip("\n")
    if not line:
        continue
    p, name, err, ds = (line.split("|") + ["", "", "", ""])[:4]
    names[p] = name
    deps[p] = set(ds.split()) if ds else set()
    if err == "ERR":
        own_err.add(p)

# Build-failure fixpoint: a package whose own build fails, or that depends on
# a broken package, is denied (needs <dep>). Policy-denied deps do not
# break the importer — they are refused for the importer's own line, not this
# one.
broken = set(own_err)
changed = True
while changed:
    changed = False
    for p, ds in deps.items():
        if p not in broken and (ds & broken):
            broken.add(p)
            changed = True

rows = []
for p in sorted(deps):
    reason = deny_reason(p)
    if reason is not None:
        rows.append(("denied", p, reason))
    elif p in own_err:
        rows.append(("denied", p, "cannot be built on GOOS=virelai"))
    elif names[p] == "main":
        rows.append(("denied", p, "command package, not importable"))
    elif p in broken:
        needs = sorted(d for d in deps[p] if d in broken)
        rows.append(("denied", p, "needs " + needs[0]))
    elif p in staged:
        rows.append(("staged", p, ""))
    else:
        rows.append(("unstaged", p, ""))

counts = {"staged": 0, "denied": 0, "unstaged": 0}
with open(out_dir + "/GOPKGS.TXT", "w") as f:
    f.write("# generated by tools/go/stage-selfhost.sh from "
            "tools/go/pkg-table.txt -- do not edit\n")
    f.write("# <state> <import-path> [reason]\n")
    for state, p, reason in rows:
        counts[state] += 1
        f.write("%s %s%s\n" % (state, p, " " + reason if reason else ""))
print("stage-selfhost: GOPKGS.TXT %d staged / %d denied / %d unstaged"
      % (counts["staged"], counts["denied"], counts["unstaged"]))
PY

# --- 2. the guest's argv, checked against the kernel's budget -----------------
# The kernel's exec copies argv into a fixed 8-slot x 256-byte block, and the
# share paths the guest passes are what make these lines longer than a normal
# command line. Both commands stay inside the budget by construction, but that
# is a claim; this asserts it.
#
# KEEP IN SYNC with tools/go/selfhost.go's `steps`: those are the lines the
# in-guest driver actually runs, and this list is their mirror. A change to one
# without the other makes this check pass for the wrong reason.
python3 - <<'PY'
MAX_ARGS = 8          # kernel/src/exec.zig max_exec_args
MAX_LEN = 256 - 1    # arg_slot_bytes, minus the NUL
# Verified on the host twin (GOOS=darwin, same flag shapes): `-p` is not
# needed — the go command passes it, but compile defaults the path from the
# input file, and the link step resolves main.main from the object's package
# path either way. Fewer args is fewer ways to exceed the block.
cmds = [
    ["GOCMDCOMPILE.ELF", "-o", "/host/HELLO.o",
     "-importcfg", "/host/GOIMPORT.CFG", "/host/HELLO.GO"],
    ["GOCMDLINK.ELF", "-importcfg", "/host/GOIMPORT.CFG", "-tmpdir", "/host",
     "-o", "/host/HELLO2.ELF", "/host/HELLO.o"],
]
bad = 0
for argv in cmds:
    if len(argv) > MAX_ARGS:
        print("stage-selfhost: FAIL %s: %d args > max_exec_args %d"
              % (argv[0], len(argv), MAX_ARGS)); bad = 1
    for a in argv:
        if len(a) > MAX_LEN:
            print("stage-selfhost: FAIL %s: %r is %d bytes > %d (arg_slot_bytes)"
                  % (argv[0], a, len(a), MAX_LEN)); bad = 1
    print("stage-selfhost: argv ok (%d/%d args, longest %d/%d): %s"
          % (len(argv), MAX_ARGS, max(len(a) for a in argv), MAX_LEN,
             " ".join(argv)))
raise SystemExit(bad)
PY

log "staged into .build/go/selfhost/ ($(ls "$OUT_DIR" | wc -l | tr -d ' ') files)"
