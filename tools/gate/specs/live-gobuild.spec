# live-gobuild.spec -- M107a (issue #2318) class-B gate: the in-guest build
# driver. GOBUILD.ELF (user/go/gobuild) walks a multi-package program's import
# graph in the guest, writes each package a -importcfg, and drives the guest's
# own GOCMDCOMPILE.ELF once per package plus GOCMDLINK.ELF once — children
# sequenced by spawn-and-wait with the B1 stream request binding each child's
# fd-1 stream to a capture file, so compiler diagnostics land in
# WSP/.BUILD/*.diag and aggregate into WSP/.BUILD/ERRORS.TXT.
#
# The fixture proves the card's acceptance and the card's three prerequisite
# measurements at once: main + FIVE local packages (six sequential compiles
# plus the link — seven children from one EL0 parent, past the "a third child
# died once" wall of #1449/ADR 0035 amendment 8) + two std imports (strconv,
# strings) resolved to staged GPKG_*.a archives, all under NESTED share paths
# (/host/WSP/<pkg>/*.go) — the nested-share proof the review notes asked for.
#
# TWO boots, same reason as live-selfhost-go: the product's run is a separate
# monitor exec so a build boot never has to host the loop's children AND the
# product at once.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gobuild.sh  -> .build/go/GOBUILD.ELF
#   bash tools/go/build-gotool.sh   -> .build/go/GOCMD*.ELF
# exec-order: assert-proven -- run 01 ends on a marker only the driver prints
# after its last child exits, and its asserts read the driver's own step
# lines; run 02 ends on the product's pinned output. A driver that never ran
# cannot go green. See tools/gate/SPEC.md.

vgate_name live-gobuild "issue #2318 M107a: the guest builds a 6-package program with its own toolchain and the product runs"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 2 BOOTS

vgate_file script.txt <<'EOF'
exec GOBUILD.ELF /host/WSP -o /host/WSPPROG.ELF
EOF

vgate_file script2.txt <<'EOF'
exec WSPPROG.ELF
EOF

vgate_file script3.txt <<'EOF'
exec GOBUILD.ELF /host/BAD
EOF

vgate_setup_python <<'PY'
import os, re, shutil, subprocess, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
repo = os.getcwd()
fixtures = [".build/go/GOBUILD.ELF", ".build/go/GOCMDCOMPILE.ELF", ".build/go/GOCMDLINK.ELF"]
for src in fixtures:
    if not os.path.exists(src):
        sys.exit("%s missing — build it first (see this spec's header): "
                 "bash tools/go/build-gobuild.sh, bash tools/go/build-gotool.sh" % src)
    shutil.copy(src, os.path.join(share, os.path.basename(src)))
    print("staged %s (%d bytes)" % (os.path.basename(src), os.path.getsize(src)))

# --- the workspace: main + five local packages + two std imports -----------
# Nested share paths under /host/WSP/<pkg>/ — itself the nested-path evidence
# the card's review notes ask for. main imports helper (which chains to
# shout -> twice), join, punct, and the std packages strconv + strings; the
# five local packages make six sequential compiles from one EL0 parent.
WSP = {
  "main.go": """package main
import (
	"helper"
	"join"
	"punct"
	"strconv"
)
func main() {
	println("wsp-build:", helper.Shout("ok")+punct.Bang(),
		"["+strconv.Itoa(42)+"]", join.Count("a", "b"))
}
""",
  "helper/helper.go": """package helper
import ("shout"; "strings")
func Shout(s string) string { return shout.Of(strings.ToUpper(s)) }
""",
  "shout/shout.go": """package shout
import "twice"
func Of(s string) string { return twice.Of(s) }
""",
  "twice/twice.go": """package twice
func Of(s string) string { return s + s }
""",
  "punct/punct.go": """package punct
func Bang() string { return "!" }
""",
  "join/join.go": """package join
import "strconv"
func Count(parts ...string) string { return strconv.Itoa(len(parts)) }
""",
}
for rel, body in WSP.items():
    path = os.path.join(share, "WSP", rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(body)
print("wrote %d fixture sources under share/WSP/" % len(WSP))

# The BROKEN workspace for run 03: helper/bad.go parses cleanly but fails
# type-checking (undefined symbol), so the driver's own parse passes it and
# GOCMDCOMPILE.ELF is the one that refuses — which makes the stream-bound
# diagnostics path observable: the child's stderr lands in the capture file,
# aggregates into BAD/.BUILD/ERRORS.TXT, and prints as a file:line:col diag.
# (A SYNTAX error would stop earlier, in the driver's graph parse, and prove
# nothing about the capture seam.)
BAD = {
  "main.go": """package main
import "helper"
func main() { println(helper.Broken()) }
""",
  "helper/bad.go": """package helper
func Broken() string { return missingSymbol }
""",
}
for rel, body in BAD.items():
    path = os.path.join(share, "BAD", rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(body)

# --- the staged archive manifest --------------------------------------------
# The driver's resolution order needs /host/GOIMPORT.CFG + GPKG_*.a archives
# naming the fixture's WHOLE std closure (the linker walks transitively), the
# same layout tools/go/stage-selfhost.sh writes for the pinned hello. The
# closure comes from the fork toolchain's `go list -export -deps` over a
# GOPATH mirror of the fixture (import paths identical: "helper", "join", ...).
gopath = os.path.join(os.environ["RUN_DIR"], "gopath")
for rel, body in WSP.items():
    # GOPATH src layout: local packages live at src/<name>; the main package
    # gets its own dir as import path "wsp" (a command). Same sources, so the
    # closure `go list` computes is the closure the guest's link walks.
    dst = os.path.join(gopath, "src", "wsp", "main.go") if rel == "main.go" \
        else os.path.join(gopath, "src", rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w") as f:
        f.write(body)

fork = os.environ.get("GO_FORK_DIR") or os.path.join(os.path.dirname(repo), "go-virelai")
go = os.path.join(fork, "bin", "go")
if not os.path.exists(go):
    sys.exit("missing fork toolchain at %s — provision once with: "
             "bash tools/go/apply.sh && just go-toolchain" % go)
env = dict(os.environ, GOROOT=fork, GOTOOLCHAIN="local", GO111MODULE="off",
           CGO_ENABLED="0", GOOS="virelai", GOARCH="arm64", GOPATH=gopath)
out = subprocess.run(
    [go, "list", "-export", "-deps", "-f", "{{.ImportPath}}|{{.Export}}", "wsp"],
    env=env, capture_output=True, text=True)
if out.returncode != 0:
    sys.exit("go list -export -deps wsp failed:\n" + out.stderr)
lines = [l for l in out.stdout.splitlines() if l.strip()]
prefix = "GPKG_"
cfg = ["# staged by live-gobuild.spec setup — the stage-selfhost.sh layout"]
total = 0
indexed = 0
for line in lines:
    path, _, export = line.partition("|")
    if path in ("wsp", "helper", "join", "punct", "shout", "twice"):
        continue  # local packages are built in-guest, never staged
    if not export:
        if path != "unsafe":
            sys.exit("%s has no export data (run `go install std`)" % path)
        continue
    name = prefix + re.sub(r"[^A-Za-z0-9]+", "_", path).strip("_") + ".a"
    if len(name) > 31:  # file_table.zig's share-name bound (stage-selfhost rule)
        name = "%s%02d.a" % (prefix, indexed)
        indexed += 1
    shutil.copyfile(export, os.path.join(share, name))
    cfg.append("packagefile %s=/host/%s" % (path, name))
    total += os.path.getsize(export)
with open(os.path.join(share, "GOIMPORT.CFG"), "w") as f:
    f.write("\n".join(cfg) + "\n")
print("staged %d std archives (%.2f MiB) + GOIMPORT.CFG" % (len(cfg) - 1, total / 1048576.0))

# Stale products must not let a broken driver go green (same rule as
# live-selfhost-go's HELLO.o/HELLO2.ELF sweep).
for stale in ("WSPPROG.ELF", "WSP/.BUILD", "BAD/.BUILD"):
    p = os.path.join(share, stale)
    if os.path.isdir(p):
        shutil.rmtree(p)
    elif os.path.exists(p):
        os.remove(p)
PY

# Run 01: the build. Six sequential GOCMDCOMPILE.ELF children + one
# GOCMDLINK.ELF from ONE EL0 parent — past the #1449 "third child" wall and
# the card's >=5-children acceptance. A link reading the std archives off the
# share at the 2048-byte EL0 cap is the slow step (live-selfhost-go measured
# ~14 s for 15 MiB); the timeout stays wide.
vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'gobuild: build OK' --timeout 900

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOBUILD.ELF'
vgate_assert 01 serial-contains 'gobuild: compile helper GOCMDCOMPILE.ELF status=0'
vgate_assert 01 serial-contains 'gobuild: compile join GOCMDCOMPILE.ELF status=0'
vgate_assert 01 serial-contains 'gobuild: compile main GOCMDCOMPILE.ELF status=0'
vgate_assert 01 serial-contains 'gobuild: link GOCMDLINK.ELF status=0'
vgate_assert 01 serial-contains 'gobuild: build OK -> /host/WSPPROG.ELF'
vgate_assert 01 serial-absent 'gobuild: FAIL'
vgate_assert 01 serial-absent 'gobuild: diag'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'cannot allocate memory'
vgate_assert 01 serial-absent 'exited status=139'

# Six local packages => six sequential compile children; assert the count
# holds so "the wall" is measured, not assumed. The product ELF gets the same
# loader-rule check live-selfhost-go runs (one copy, tools/lib/elf_rules.py),
# and the driver's per-step times are reported (a property of the machine,
# asserted nowhere).
vgate_assert 01 python <<'PY'
import os, re, sys
sys.path.insert(0, os.path.join("tools", "lib"))
import elf_rules
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
ser = open(os.environ["VG_SER"], errors="replace").read()
compiles = re.findall(r"gobuild: compile (\S+) GOCMDCOMPILE\.ELF status=(\d+) ms=(\d+)", ser)
if len(compiles) < 5:
    sys.exit("FAIL: only %d sequential GOCMDCOMPILE children; card needs >= 5" % len(compiles))
print("sequential compile children: %d" % len(compiles))
for name, st, ms in compiles:
    print("  compile %-8s status=%s %s ms" % (name, st, ms))
    if st != "0":
        sys.exit("FAIL: compile %s status=%s" % (name, st))
m = re.search(r"gobuild: link GOCMDLINK\.ELF status=(\d+) ms=(\d+)", ser)
if not m:
    sys.exit("FAIL: no link step line")
print("link status=%s %s ms" % (m.group(1), m.group(2)))
elf = os.path.join(share, "WSPPROG.ELF")
if not os.path.exists(elf):
    sys.exit("FAIL: the build produced no ELF at " + elf)
receipt, fails = elf_rules.check_file(elf, "WSPPROG.ELF")
print(receipt)
if fails:
    for f in fails:
        print("FAIL: " + f)
    sys.exit(1)
errs = os.path.join(share, "WSP", ".BUILD", "ERRORS.TXT")
if not os.path.exists(errs):
    sys.exit("FAIL: no ERRORS.TXT (the M107c diagnostics file)")
if os.path.getsize(errs) != 0:
    sys.exit("FAIL: ERRORS.TXT nonempty on a clean build: " + open(errs).read())
print("the build's ELF satisfies every loader rule; ERRORS.TXT is clean")
PY

# Run 02: the product the guest built, executed by the kernel (the RUN half —
# one monitor exec, same shape as live-selfhost-go run 02).
vgate_run 02 -- --script '$RUN_DIR/script2.txt' --script-expect 'wsp-build: OKOK! [42] 2' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded'
vgate_assert 02 serial-contains 'wsp-build: OKOK! [42] 2'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 serial-absent 'cannot allocate memory'

# Run 03: the diagnostics path. BAD/helper/bad.go fails compilation, so the
# run ends on the driver's FAIL marker and the asserts pin the captured
# compiler diagnostic: file:line on the console AND in the ERRORS.TXT file
# M107c will consume — proving the B1 stream binding actually carried the
# child's stderr, not merely that the spawn was accepted.
vgate_run 03 -- --script '$RUN_DIR/script3.txt' --script-expect 'gobuild: FAIL' --timeout 300

vgate_assert 03 serial-contains 'exec: loaded GOBUILD.ELF'
vgate_assert 03 serial-contains 'gobuild: compile helper GOCMDCOMPILE.ELF status='
vgate_assert 03 serial-contains 'gobuild: diag'
vgate_assert 03 serial-contains 'bad.go:'
vgate_assert 03 serial-contains 'gobuild: FAIL'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'cannot allocate memory'
vgate_assert 03 share-contains 'BAD/.BUILD/ERRORS.TXT' 'bad.go'
