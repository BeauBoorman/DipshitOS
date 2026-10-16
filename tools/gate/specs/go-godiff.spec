# go-godiff.spec -- M107e (#2322) class-B fleet spec for GODIFF.ELF: a
# unified context diff for two share files, staged host-built like every
# other fleet ELF. The capstone's in-guest provenance proof lives in
# live-godiff-loop.spec; this spec is the fleet-behavior gate every app
# gets: real diffs, the identical/refusal/usage surfaces, the -u context
# flag and the "\ No newline" ending marker.
#
# The legs chain on the kernel's own exit line (`procs GODIFF.ELF exited
# status=N`) — the async exec contract means each leg's output is only
# sequenced by waiting for the previous leg to die. Three phases fit per
# run (script + script2 + script3), so run 01 covers the change/identical/
# io legs and run 02 covers usage/-u/eol.
#
# exec-order: assert-proven -- every leg ends on `procs GODIFF.ELF exited
# status=N`, which only prints after that program ran; a green run proves
# each exec'd leg executed (no script-echo race, tools/gate/SPEC.md).
#
# HOST PREREQ:
#   bash tools/go/build-godiff.sh  -> .build/go/GODIFF.ELF

vgate_name go-godiff "M107e #2322: GODIFF.ELF fleet spec - unified context diff over share files"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# ---- fixtures -------------------------------------------------------------------
# A/B: an ordinary mid-file change. C/D: two changes a -u1 merge refuses
# to merge (3 keep lines > 2*1), so -u3 merges and -u1 splits. E/ENOeol:
# the unterminated-last-line case.
vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "GODIFF.ELF")
if not os.path.isfile(src):
    sys.exit("GODIFF.ELF missing (expected " + src + ") - "
             "build it first: bash tools/go/build-godiff.sh")
shutil.copy(src, os.path.join(share, "GODIFF.ELF"))
open(os.path.join(share, "A.TXT"), "w").write(
    "alpha\nbeta\ngamma\ndelta\nepsilon\n")
open(os.path.join(share, "B.TXT"), "w").write(
    "alpha\nbeta\nGAMMA\ndelta\nepsilon\n")
open(os.path.join(share, "C.TXT"), "w").write(
    "x\n1\n2\n3\ny\n")
open(os.path.join(share, "D.TXT"), "w").write(
    "X\n1\n2\n3\nY\n")
open(os.path.join(share, "E.TXT"), "w").write("tail\n")
open(os.path.join(share, "ENOEOL.TXT"), "w").write("tail")
print("staged GODIFF.ELF + diff fixtures")
PY

vgate_file script-leg1.txt <<'EOF'
exec GODIFF.ELF /host/A.TXT /host/B.TXT
EOF
vgate_file script-leg2.txt <<'EOF'
exec GODIFF.ELF /host/A.TXT /host/A.TXT
EOF
vgate_file script-leg3.txt <<'EOF'
exec GODIFF.ELF /host/A.TXT /host/MISSING.TXT
EOF
vgate_file script-leg4.txt <<'EOF'
exec GODIFF.ELF
EOF
vgate_file script-leg5.txt <<'EOF'
exec GODIFF.ELF -u1 /host/C.TXT /host/D.TXT
EOF
vgate_file script-leg6.txt <<'EOF'
exec GODIFF.ELF /host/E.TXT /host/ENOEOL.TXT
EOF

# ---- 01: change + identical + io refusal ---------------------------------------
vgate_run 01 -- \
    --script '$RUN_DIR/script-leg1.txt' \
    --script2 '$RUN_DIR/script-leg2.txt' --script2-after 'procs GODIFF.ELF exited status=1' \
    --script3 '$RUN_DIR/script-leg3.txt' --script3-after 'procs GODIFF.ELF exited status=0' \
    --script-expect 'godiff: read /host/MISSING.TXT refused' --script-expect-tail 6 \
    --timeout 240

vgate_assert 01 serial-contains 'exec: loaded GODIFF.ELF'
# leg1: the real unified diff, headers carrying the argv spellings.
vgate_assert 01 serial-contains '--- /host/A.TXT'
vgate_assert 01 serial-contains '+++ /host/B.TXT'
vgate_assert 01 serial-contains '@@ -1,5 +1,5 @@'
vgate_assert 01 serial-contains '-gamma'
vgate_assert 01 serial-contains '+GAMMA'
vgate_assert 01 serial-contains 'godiff: files differ hunks=1'
vgate_assert 01 serial-contains 'procs GODIFF.ELF exited status=1'
# leg2: identical inputs exit 0 with the named marker.
vgate_assert 01 serial-contains 'godiff: /host/A.TXT and /host/A.TXT are identical'
vgate_assert 01 serial-contains 'procs GODIFF.ELF exited status=0'
# leg3: a missing file is a named refusal, exit 3.
vgate_assert 01 serial-contains 'godiff: read /host/MISSING.TXT refused rc='
vgate_assert 01 serial-contains 'procs GODIFF.ELF exited status=3'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# ---- 02: usage + -u split + "\ No newline" -------------------------------------
vgate_run 02 -- \
    --script '$RUN_DIR/script-leg4.txt' \
    --script2 '$RUN_DIR/script-leg5.txt' --script2-after 'procs GODIFF.ELF exited status=2' \
    --script3 '$RUN_DIR/script-leg6.txt' --script3-after 'godiff: files differ hunks=2' \
    --script-expect 'No newline at end of file' --script-expect-tail 6 \
    --timeout 240

vgate_assert 02 serial-contains 'godiff: usage: GODIFF.ELF [-u<n>] <a> <b>'
vgate_assert 02 serial-contains 'procs GODIFF.ELF exited status=2'
# leg5: -u1 keeps the two changes in separate hunks (the >2*1 gap rule).
vgate_assert 02 serial-contains '@@ -1,2 +1,2 @@'
vgate_assert 02 serial-contains '@@ -4,2 +4,2 @@'
vgate_assert 02 serial-contains 'godiff: files differ hunks=2'
# leg6: "tail\n" vs "tail" -- the ending difference is reported, and the
# marker lands under the unterminated side.
vgate_assert 02 serial-contains '-tail'
vgate_assert 02 serial-contains '+tail'
vgate_assert 02 serial-contains '\ No newline at end of file'
vgate_assert 02 serial-contains 'procs GODIFF.ELF exited status=1'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
