# live-gobuild.spec -- M107a (issue #2318) class-B gate: the in-guest build
# driver, plus the M107b (#2319) refusal surface. GOBUILD.ELF (user/go/gobuild)
# walks a multi-package program's import graph in the guest, writes each
# package a -importcfg, and drives the guest's own GOCMDCOMPILE.ELF once per
# package plus GOCMDLINK.ELF once — children sequenced by spawn-and-wait with
# the B1 stream request binding each child's fd-1 stream to a capture file, so
# compiler diagnostics land in WSP/.BUILD/*.diag and aggregate into
# WSP/.BUILD/ERRORS.TXT.
#
# The fixture proves the card's acceptance and the card's three prerequisite
# measurements at once: main + FIVE local packages (six sequential compiles
# plus the link — seven children from one EL0 parent, past the "a third child
# died once" wall of #1449/ADR 0035 amendment 8) + two std imports (strconv,
# strings) resolved to staged GPKG_*.a archives, all under NESTED share paths
# (/host/WSP/<pkg>/*.go) — the nested-share proof the review notes asked for.
#
# M107b adds runs 04-05: the named refusals. The staged artifacts are now the
# REAL ones — .build/go/selfhost/{GOIMPORT.CFG,GOPKGS.TXT,GPKG_*.a} written by
# tools/go/stage-selfhost.sh from tools/go/pkg-table.txt — so a denied package
# refuses dep_unsupported against the shipped table (run 04) and an over-cap
# local closure refuses closure_too_large before a single child spawns
# (run 05). Both refuse in the graph phase, so no compile line may appear.
#
# TWO boots for the build+run, same reason as live-selfhost-go: the product's
# run is a separate monitor exec so a build boot never has to host the loop's
# children AND the product at once. The refusal runs need no product boot.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gobuild.sh   -> .build/go/GOBUILD.ELF
#   bash tools/go/build-gotool.sh    -> .build/go/GOCMD*.ELF
#   bash tools/go/stage-selfhost.sh  -> .build/go/selfhost/{GOIMPORT.CFG,
#                                       GOPKGS.TXT,GPKG_*.a}
# exec-order: assert-proven -- run 01 ends on a marker only the driver prints
# after its last child exits, and its asserts read the driver's own step
# lines; run 02 ends on the product's pinned output; runs 03-05 end on the
# driver's own FAIL marker with asserts that read driver-produced text only.
# A driver that never ran cannot go green. See tools/gate/SPEC.md.

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

vgate_file script4.txt <<'EOF'
exec GOBUILD.ELF /host/DENIED
EOF

vgate_file script5.txt <<'EOF'
exec GOBUILD.ELF /host/OVERCAP
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
repo = os.getcwd()
fixtures = [".build/go/GOBUILD.ELF", ".build/go/GOCMDCOMPILE.ELF", ".build/go/GOCMDLINK.ELF"]
for src in fixtures:
    if not os.path.exists(src):
        sys.exit("%s missing — build it first (see this spec's header): "
                 "bash tools/go/build-gobuild.sh, bash tools/go/build-gotool.sh" % src)
    shutil.copy(src, os.path.join(share, os.path.basename(src)))
    print("staged %s (%d bytes)" % (os.path.basename(src), os.path.getsize(src)))

# --- the REAL staged surface (M107b): the manifest, the package table and ---
# the GPKG_*.a archives exactly as tools/go/stage-selfhost.sh wrote them from
# tools/go/pkg-table.txt. The WSP fixture's std imports (strconv, strings) are
# inside the allowlist closure; the driver's resolution order and the refusal
# oracle are what a real in-guest build sees, not a spec-local mirror.
selfhost = os.path.join(repo, ".build", "go", "selfhost")
for need in ("GOIMPORT.CFG", "GOPKGS.TXT"):
    if not os.path.exists(os.path.join(selfhost, need)):
        sys.exit(".build/go/selfhost/%s missing — stage it first "
                 "(see this spec's header): bash tools/go/stage-selfhost.sh" % need)
n_arch = total = 0
for name in sorted(os.listdir(selfhost)):
    if name.startswith("GPKG_") and name.endswith(".a") or \
       name in ("GOIMPORT.CFG", "GOPKGS.TXT"):
        src = os.path.join(selfhost, name)
        shutil.copy(src, os.path.join(share, name))
        total += os.path.getsize(src)
        if name.endswith(".a"):
            n_arch += 1
print("staged %d archives + GOIMPORT.CFG + GOPKGS.TXT from "
      ".build/go/selfhost (%.2f MiB)" % (n_arch, total / 1048576.0))

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

# The DENIED workspace for run 04: a program importing crypto/x509 — a real
# std package the GOOS=virelai port cannot build (no system cert-root store)
# and GOPKGS.TXT therefore carries as `denied`. The refusal must be the
# driver's named dep_unsupported — the package and the table's reason on the
# console and in ERRORS.TXT — not a toolchain panic, and no compile child may
# spawn at all.
DENIED = {
  "main.go": """package main
import "crypto/x509"
func main() { _ = x509.ErrUnsupportedAlgorithm }
""",
}
for rel, body in DENIED.items():
    path = os.path.join(share, "DENIED", rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(body)

# The OVERCAP workspace for run 05: main plus 64 local packages — 65 locals,
# one past the driver's 64-package cap. The graph phase must refuse
# closure_too_large BEFORE any compile child spawns; the cap exists so a
# pathological closure cannot spend the boot budget on sequential
# GOCMDCOMPILE.ELF children.
imports = "\n".join('\t_ "p%02d"' % i for i in range(64))
os.makedirs(os.path.join(share, "OVERCAP"), exist_ok=True)
with open(os.path.join(share, "OVERCAP", "main.go"), "w") as f:
    f.write("package main\nimport (\n%s\n)\nfunc main() {}\n" % imports)
for i in range(64):
    d = os.path.join(share, "OVERCAP", "p%02d" % i)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "p.go"), "w") as f:
        f.write("package p%02d\nvar V int\n" % i)
print("wrote DENIED + OVERCAP fixtures (1 and 65 files)")

# Stale products must not let a broken driver go green (same rule as
# live-selfhost-go's HELLO.o/HELLO2.ELF sweep).
for stale in ("WSPPROG.ELF", "WSP/.BUILD", "BAD/.BUILD",
              "DENIED/.BUILD", "OVERCAP/.BUILD"):
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

# Run 04 (M107b): the named refusal for a denied package. DENIED imports
# crypto/x509, which GOPKGS.TXT carries as `denied` — the driver must print
# dep_unsupported naming the package and the table's reason, land the same
# in ERRORS.TXT, and never spawn a compile child. `serial-absent` on the
# compile line is the proof the refusal happened in the graph phase.
vgate_run 04 -- --script '$RUN_DIR/script4.txt' --script-expect 'gobuild: FAIL' --timeout 120

vgate_assert 04 serial-contains 'exec: loaded GOBUILD.ELF'
vgate_assert 04 serial-contains 'dep_unsupported'
vgate_assert 04 serial-contains 'crypto/x509'
vgate_assert 04 serial-contains 'cert-root'
vgate_assert 04 serial-contains 'gobuild: FAIL'
vgate_assert 04 serial-absent 'gobuild: compile '
vgate_assert 04 serial-absent 'gobuild: link '
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'cannot allocate memory'
vgate_assert 04 serial-absent 'panic:'
vgate_assert 04 share-contains 'DENIED/.BUILD/ERRORS.TXT' 'dep_unsupported'
vgate_assert 04 share-contains 'DENIED/.BUILD/ERRORS.TXT' 'crypto/x509'

# Run 05 (M107b): the package cap. OVERCAP is main + 64 local packages = 65
# locals > the driver's 64 cap; the refusal is closure_too_large before a
# single GOCMDCOMPILE.ELF spawn — a pathological closure must not get to
# spend the boot budget on sequential compiles.
vgate_run 05 -- --script '$RUN_DIR/script5.txt' --script-expect 'gobuild: FAIL' --timeout 120

vgate_assert 05 serial-contains 'exec: loaded GOBUILD.ELF'
vgate_assert 05 serial-contains 'closure_too_large'
vgate_assert 05 serial-contains 'cap 64'
vgate_assert 05 serial-contains 'gobuild: FAIL'
vgate_assert 05 serial-absent 'gobuild: compile '
vgate_assert 05 serial-absent 'gobuild: link '
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'cannot allocate memory'
vgate_assert 05 share-contains 'OVERCAP/.BUILD/ERRORS.TXT' 'closure_too_large'
