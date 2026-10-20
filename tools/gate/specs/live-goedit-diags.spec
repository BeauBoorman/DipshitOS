# live-goedit-diags.spec -- M107c (issue #2320) class-B gate: GOEDIT reads a
# build's ERRORS.TXT and navigates it. Run 01: GOBUILD.ELF fails /host/EDBAD
# at the driver stage (positioned no_package + bad_package diags, no
# toolchain children), GOEDIT opens the file, Ctrl-E populates the list, and
# Enter/ctrl-n/ctrl-p jump file:line:col — the cross-file row swaps the one
# buffer. Run 02's fix+rebuild runs in a seat-less boot — with tabwm up,
# the second sequential compile child answers -ENOSPC (twice observed:
# rc=-5) because a just-exited child's slots are not reaped instantly.
# Run 03 then reads the clean build's empty ERRORS.TXT off the persisted
# share: `errors none` — the card's clear-on-success. Run 04: a save after
# the build makes the list `errors stale` — the saved-since refusal through
# slot-79 mtimes. Run 05 (M138b #2776): a seeded one-row ERRORS.TXT in its
# own EDFMT workspace — ctrl-n jumps to the exact column (status err=1/1),
# and ctrl-s runs format-on-save, which on the shipped build prints the
# named refusal and publishes verbatim (the python assert checks the bytes
# against whichever path the binary took).
#
# Its own spec, not a go-edit leg, for the same reason live-gobuild stands
# alone: the toolchain staging (fork `go list -export -deps` + archives) is
# a prerequisite the editor's other runs must not pay.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goedit.sh  -> .build/go/GOEDIT.ELF
#   bash tools/go/build-gobuild.sh -> .build/go/GOBUILD.ELF
#   bash tools/go/build-gosh.sh    -> .build/go/GOSH.ELF
#   bash tools/go/build-gotool.sh  -> .build/go/GOCMD*.ELF
# exec-order: assert-proven -- run 01 ends on `goedit: errors end`, printed
# only after the last chord; run 02 on `build OK`; 03 on `errors none`; 04
# on `errors stale`; 05's close script is stage-gated on `goedit: saved `.
# A program that never ran cannot pass. SPEC.md.

vgate_name live-goedit-diags "issue #2320 M107c: GOEDIT navigates ERRORS.TXT file:line:col diagnostics on VZ"
# seed-virtiofs, not seed: the stale check stats through the slot-79
# metadata backend, which refuses the custom-virtio channel outright
# (observed: stat rc=-4 on the cv share — the go-shell-polish note).
vgate_share seed-virtiofs
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_setup_python <<'PY'
import os, re, shutil, subprocess, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
repo = os.getcwd()
fixtures = [".build/go/GOEDIT.ELF", ".build/go/GOBUILD.ELF", ".build/go/GOSH.ELF",
            ".build/go/GOCMDCOMPILE.ELF", ".build/go/GOCMDLINK.ELF"]
for src in fixtures:
    if not os.path.exists(src):
        sys.exit("%s missing — build it first (see this spec's header)" % src)
    shutil.copy(src, os.path.join(share, os.path.basename(src)))
    print("staged %s (%d bytes)" % (os.path.basename(src), os.path.getsize(src)))

# --- the broken workspace ---------------------------------------------------
# main.go imports "helper" (a local package whose second file declares the
# WRONG package name — a deterministic bad_package diag) and "missing" (a
# no_package diag). Both diags carry file:line:col and both are produced at
# the driver's graph stage, so run 01's build needs no toolchain children.
def w(rel, body):
    p = os.path.join(share, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(body)

w("EDBAD/main.go",
  "package main\n"
  "import \"helper\"\n"
  "import \"missing\"\n"
  "func main() { println(helper.Of(\"x\")) }\n")
w("EDBAD/helper/helper.go",
  "package helper\n"
  "func Of(s string) string { return s }\n")
w("EDBAD/helper/bad.go",
  "package wrong\n"
  "func Nope() {}\n")

# The fixed sources run 02 cats into place: the missing import is gone and
# bad.go declares the right package, so the rebuild compiles + links.
w("EDFIX/main.go",
  "package main\n"
  "import \"helper\"\n"
  "func main() { println(helper.Of(\"ok\")) }\n")
w("EDFIX/bad.go",
  "package helper\n"
  "func Nope() {}\n")

# --- the stale-leg workspace -------------------------------------------------
# One positioned driver diag; run 04 saves the file after the build and the
# mtime rule refuses the list.
w("EDSTALE/main.go",
  "package main\n"
  "import \"missing\"\n"
  "func main() {}\n")

# --- the staged archive manifest --------------------------------------------
# The FIXED program's whole std closure, the same GOIMPORT.CFG + GPKG_*.a
# layout live-gobuild uses: `go list -export -deps` over a GOPATH mirror of
# the fixed sources (import path "helper" identical, command "edfix").
gopath = os.path.join(os.environ["RUN_DIR"], "gopath")
src_main = open(os.path.join(share, "EDFIX", "main.go")).read()
src_help = open(os.path.join(share, "EDBAD", "helper", "helper.go")).read()
src_bad = open(os.path.join(share, "EDFIX", "bad.go")).read()
for rel, body in [("edfix/main.go", src_main), ("helper/helper.go", src_help),
                  ("helper/bad.go", src_bad)]:
    p = os.path.join(gopath, "src", rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(body)

fork = os.environ.get("GO_FORK_DIR") or os.path.join(os.path.dirname(repo), "go-virelai")
go = os.path.join(fork, "bin", "go")
if not os.path.exists(go):
    sys.exit("missing fork toolchain at %s — provision once with: "
             "bash tools/go/apply.sh && just go-toolchain" % go)
env = dict(os.environ, GOROOT=fork, GOTOOLCHAIN="local", GO111MODULE="off",
           CGO_ENABLED="0", GOOS="virelai", GOARCH="arm64", GOPATH=gopath)
out = subprocess.run(
    [go, "list", "-export", "-deps", "-f", "{{.ImportPath}}|{{.Export}}", "edfix"],
    env=env, capture_output=True, text=True)
if out.returncode != 0:
    sys.exit("go list -export -deps edfix failed:\n" + out.stderr)
lines = [l for l in out.stdout.splitlines() if l.strip()]
cfg = ["# staged by live-goedit-diags.spec setup — the stage-selfhost layout"]
total = 0
indexed = 0
for line in lines:
    path, _, export = line.partition("|")
    if path in ("edfix", "helper"):
        continue  # local packages are built in-guest, never staged
    if not export:
        if path != "unsafe":
            sys.exit("%s has no export data (run `go install std`)" % path)
        continue
    name = "GPKG_" + re.sub(r"[^A-Za-z0-9]+", "_", path).strip("_") + ".a"
    if len(name) > 31:  # file_table.zig's share-name bound
        name = "GPKG_%02d.a" % indexed
        indexed += 1
    shutil.copyfile(export, os.path.join(share, name))
    cfg.append("packagefile %s=/host/%s" % (path, name))
    total += os.path.getsize(export)
with open(os.path.join(share, "GOIMPORT.CFG"), "w") as f:
    f.write("\n".join(cfg) + "\n")
print("staged %d std archives (%.2f MiB) + GOIMPORT.CFG" % (len(cfg) - 1, total / 1048576.0))

# Stale products must not let a broken run go green.
for stale in ("EDBAD/.BUILD", "EDSTALE/.BUILD", "EDBAD/EDBAD.ELF",
              "EDFMT/.BUILD"):
    p = os.path.join(share, stale)
    if os.path.isdir(p):
        shutil.rmtree(p)
    elif os.path.exists(p):
        os.remove(p)
PY

# --- the M138b (#2776) jump+save workspace ----------------------------------
# Run 05's own package: an unformatted main.go plus a hand-written
# .BUILD/ERRORS.TXT — no build needed, the seeded list carries one
# positioned diag (line 2, col 13 = the ')' in the unformatted signature).
# ERRORS.TXT is written AFTER main.go so the mtime order reads as a fresh
# build, never `stale`.
vgate_setup_python <<'PY'
import os
share = os.path.join(os.environ["RUN_DIR"], "share")
d = os.path.join(share, "EDFMT", ".BUILD")
os.makedirs(d, exist_ok=True)
with open(os.path.join(share, "EDFMT", "main.go"), "w") as f:
    f.write("package main\nfunc  main( ) { println(1) }\n")
with open(os.path.join(d, "ERRORS.TXT"), "w") as f:
    f.write("/host/EDFMT/main.go:2:13: gofmt would rewrite this file\n")
print("staged EDFMT workspace")
PY

# --- run 01: broken build -> populate -> jump -> step -> cross-file ---------
# GOBUILD fails EDBAD at the graph stage; BFS loads a discovered package
# before finishing the parent's imports, so ERRORS.TXT lists the helper row
# FIRST:
#   /host/EDBAD/helper/helper.go:1:9: package helper in dir expecting wrong
#   /host/EDBAD/main.go:3:8: cannot find package "missing" ...
# GOEDIT opens main.go, Ctrl-E loads the list (n=2), down selects the
# main.go row, Return jumps 3:8; ctrl-p steps to the helper row — the
# cross-file jump swaps the buffer to helper.go and lands 1:9; ctrl-n
# steps back to main.go and the second ctrl-n ends on the named refusal.
vgate_file script2.txt <<'EOF'
exec GOBUILD.ELF /host/EDBAD
EOF

vgate_file script3.txt <<'EOF'
exec GOEDIT.ELF /host/EDBAD/main.go
EOF

vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gobuild: FAIL' \
    --input-chords 'ctrl-e,down,return,ctrl-p,ctrl-n,ctrl-n' \
    --input-chords-after 'goedit: present' \
    --script-expect 'goedit: errors end' --timeout 300

vgate_assert 01 serial-contains 'exec: loaded GOBUILD.ELF'
vgate_assert 01 serial-contains 'gobuild: diag /host/EDBAD/main.go:3:8: cannot find package'
vgate_assert 01 serial-contains 'gobuild: FAIL'
vgate_assert 01 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 01 serial-contains 'goedit: read /host/EDBAD/main.go n='
# Ctrl-E populated the list: two positioned diagnostics.
vgate_assert 01 serial-contains 'goedit: errors n=2'
# Down selected the main.go row; Return jumped to its 3:8.
vgate_assert 01 serial-contains 'goedit: errors sel=2/2'
vgate_assert 01 serial-contains 'goedit: errors jump line=3 col=8'
vgate_assert 01 serial-contains 'goedit: status line=3/5 col=8'
# ctrl-p stepped to the helper row — the buffer swapped files and landed 1:9.
vgate_assert 01 serial-contains 'goedit: read /host/EDBAD/helper/helper.go n='
vgate_assert 01 serial-contains 'goedit: errors jump line=1 col=9'
vgate_assert 01 serial-contains 'goedit: status line=1/3 col=9'
# The second ctrl-n walked off the end — the named refusal is the run's tail.
vgate_assert 01 serial-contains 'goedit: errors end'
vgate_assert 01 serial-absent 'goedit: errors stale'
vgate_assert 01 serial-absent 'goedit: errors dirty'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
# The diagnostics file is the M107a artifact the gate cross-checks.
vgate_assert 01 share-contains 'EDBAD/.BUILD/ERRORS.TXT' 'main.go:3:8'
vgate_assert 01 share-contains 'EDBAD/.BUILD/ERRORS.TXT' 'helper.go:1:9'

# --- run 02: fix -> rebuild in a seat-less boot ------------------------------
# Two observed facts shape this run. First, GOSH -c is headless — the fix
# (two cats) needs no window. Second, the seat is what spends the 13th EL0
# slot: with tabwm up, the SECOND sequential compile child spawn answers
# -ENOSPC — the just-exited first child's slots are not reaped fast enough
# (twice observed: rc=-5 both nested and direct). live-gobuild proves seven
# sequential children fit when no seat is up, so the fix+rebuild run drops
# tabwm entirely and keeps the editor legs to the runs that need it.
vgate_file script-02.txt <<'EOF'
exec GOSH.ELF -c "cat /host/EDFIX/main.go > /host/EDBAD/main.go && cat /host/EDFIX/bad.go > /host/EDBAD/helper/bad.go && echo rx-edfix-ok"
EOF

vgate_file script2-02.txt <<'EOF'
exec GOBUILD.ELF /host/EDBAD
EOF

# warm-cold: 02 (f) run 03 reads the share fixes this leg publishes
#   ('the share persists across the spec's boots') — converting 02
#   would wall its writes inside a private clone and starve 03
#   (M131d #2641, ADR 0059 D7(f))
vgate_run 02 -- \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'rx-edfix-ok' \
    --script-expect 'gobuild: build OK' --timeout 600

vgate_assert 02 serial-contains 'exec: loaded GOSH.ELF'
vgate_assert 02 serial-contains 'exec: loaded GOBUILD.ELF'
vgate_assert 02 serial-contains 'gobuild: compile helper GOCMDCOMPILE.ELF status=0'
vgate_assert 02 serial-contains 'gobuild: compile main GOCMDCOMPILE.ELF status=0'
vgate_assert 02 serial-contains 'gobuild: link GOCMDLINK.ELF status=0'
vgate_assert 02 serial-contains 'gobuild: build OK -> /host/EDBAD/EDBAD.ELF'
vgate_assert 02 serial-absent 'gobuild: FAIL'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# The clean build's ERRORS.TXT: exists, zero bytes — and the fixed sources
# landed where the cats wrote them (host-side proof the fix published).
vgate_assert 02 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
p = os.path.join(share, "EDBAD", ".BUILD", "ERRORS.TXT")
if not os.path.exists(p):
    sys.exit("no ERRORS.TXT after the clean build")
if os.path.getsize(p) != 0:
    sys.exit("ERRORS.TXT nonempty after a clean build: " + open(p).read())
fixed = open(os.path.join(share, "EDBAD", "main.go")).read()
if "missing" in fixed:
    sys.exit("the cat fix never landed on EDBAD/main.go")
bad = open(os.path.join(share, "EDBAD", "helper", "bad.go")).read()
if "package helper" not in bad:
    sys.exit("the cat fix never landed on EDBAD/helper/bad.go")
print("clean build left an empty ERRORS.TXT; fixed sources verified on the host")
PY

# --- run 03: the clean build's empty list reads as `errors none` ------------
# The share persists across the spec's boots (the live-gobuild precedent:
# run 02 there executes run 01's product), so this boot's GOEDIT reads the
# ERRORS.TXT run 02's rebuild left — empty, so Ctrl-E answers `none`. That
# is the card's "errors clear on successful build".
vgate_file script2-03.txt <<'EOF'
exec GOEDIT.ELF /host/EDBAD/main.go
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'ctrl-e' \
    --input-chords-after 'goedit: present' \
    --script-expect 'goedit: errors none' --timeout 240

vgate_assert 03 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 03 serial-contains 'goedit: read /host/EDBAD/main.go n='
vgate_assert 03 serial-contains 'goedit: errors none'
vgate_assert 03 serial-absent 'goedit: errors n='
vgate_assert 03 serial-absent 'goedit: errors jump'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# --- run 04: a save after the build is the `stale` refusal ------------------
# EDSTALE fails with one positioned diag; GOEDIT lists it, Escape closes the
# panel back to the document (the panel eats document keys while open —
# observed: an unclosed panel swallowed the 'x'), 'x' + ctrl-s publishes the
# buffer — the file's mtime now postdates the build — and the next Ctrl-E
# answers `errors stale`: a stale error list never shows for a file saved
# since.
vgate_file script2-04.txt <<'EOF'
exec GOBUILD.ELF /host/EDSTALE
EOF

vgate_file script3-04.txt <<'EOF'
exec GOEDIT.ELF /host/EDSTALE/main.go
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-04.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script3-04.txt' \
    --script3-after 'gobuild: FAIL' \
    --input-chords 'ctrl-e,escape,x,ctrl-s,ctrl-e' \
    --input-chords-after 'goedit: present' \
    --script-expect 'goedit: errors stale' --timeout 300

vgate_assert 04 serial-contains 'gobuild: FAIL'
vgate_assert 04 serial-contains 'goedit: errors n=1'
vgate_assert 04 serial-contains 'goedit: saved /host/EDSTALE/main.go'
vgate_assert 04 serial-contains 'goedit: errors stale'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

# --- M138b (#2776) run 05: exact-column jump + format-or-refusal save ------
# The seeded EDFMT list carries one positioned diag; ctrl-n (the editor's
# own next-diagnostic chord — GOEDIT's keymap, not the registry's) loads
# and jumps straight to line 2 col 13 — the ')' in the unformatted
# signature — and the status line carries the new `err=1/1` count with the
# landing column. Ctrl-S then runs format-on-save: the probe-measured
# build has no go/format (the image would exceed exec_program_max), so
# the save prints the card's named refusal and publishes the buffer
# verbatim — the python assert checks the bytes against whichever path
# the binary actually took, so the leg stays honest if a future cap bump
# ships the `editfmt` build.
vgate_file script2-05.txt <<'EOF'
exec GOEDIT.ELF /host/EDFMT/main.go
EOF

vgate_file script3-05.txt <<'EOF'
dui close 2
echo rx-edfmt-ok
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-05.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'ctrl-n,ctrl-s' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-05.txt' \
    --script3-after 'goedit: saved ' \
    --script-expect 'rx-edfmt-ok' --timeout 300

vgate_assert 05 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 05 serial-contains 'goedit: read /host/EDFMT/main.go n=42'
vgate_assert 05 serial-contains 'goedit: errors n=1'
# The jump lands on the diagnostic's exact column: ')' at 2:13.
vgate_assert 05 serial-contains 'goedit: errors jump line=2 col=13'
# The buffer counts the trailing newline's empty tail as a third line, so
# the landing status reads 2/3, not 2/2.
vgate_assert 05 serial-contains 'goedit: status line=2/3 col=13 err=1/1'
# The shipped probe verdict: go/format is not guest-safe on image size, so
# Ctrl-S names the refusal and still publishes.
vgate_assert 05 serial-contains 'edit: format unavailable (go/format not guest-safe)'
vgate_assert 05 serial-contains 'goedit: saved /host/EDFMT/main.go n=42'
vgate_assert 05 serial-contains 'rx-edfmt-ok'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'

# The bytes on the share decide which path the save took and require the
# matching one: the refusal leaves the seed verbatim, a real go/format
# leaves the gofmt output — anything else fails.
vgate_assert 05 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
share = os.environ["VG_SHARE"]
got = open(os.path.join(share, "EDFMT", "main.go"), "rb").read()
seed = b"package main\nfunc  main( ) { println(1) }\n"
fmt = b"package main\n\nfunc main() { println(1) }\n"
if "edit: format unavailable" in ser:
    assert got == seed, "refusal path must publish verbatim: %r" % got
    print("format unavailable: verbatim save verified (%d bytes)" % len(got))
else:
    assert "goedit: format n=" in ser, "no refusal and no format receipt — which path ran?"
    assert got == fmt, "format path must publish gofmt output: %r" % got
    print("format-on-save verified: %d bytes" % len(got))
PY
