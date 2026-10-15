# go-btmath.spec -- Bubble Tea on VirelaiOS: the framework itself runs here.
#
# Subject: user/go/btmath, a tea.Model/Init-Update-View program built with
# charm.land/bubbletea/v2 for GOOS=virelai. Nothing in the framework is
# reimplemented: Bubble Tea's own Program loop, renderer, key decoding and
# WindowSize handling run on this OS. Only two seams come from the guest -- input
# (an io.Reader via tea.WithInput) and output (the kernel console via
# tea.WithOutput) -- plus tea.WithWindowSize, because a VirelaiOS console is not
# a POSIX tty to ioctl a size from.
#
# The load-bearing evidence is NOT the app's own markers: the last assert reads
# /host/BTMATH/SESSION.TXT back ON THE HOST and requires the exact record the
# scripted session must produce (played 5, score 65, 3 correct, 2 wrong). A stub
# that printed success without running the model cannot pass that.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-btmath.sh   ->   .build/go/BTMATH.ELF
#
# exec-order: assert-proven -- the run ends on `btmath: OK`, which only the
# program prints after saving the session.

vgate_name go-btmath "Bubble Tea (charm.land/bubbletea/v2) runs a TUI on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec BTMATH.ELF --selftest
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "BTMATH.ELF")
if not os.path.exists(src):
    sys.exit("BTMATH.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-btmath.sh")
shutil.copy(src, os.path.join(share, "BTMATH.ELF"))
os.makedirs(os.path.join(share, "BTMATH"), exist_ok=True)
print("staged BTMATH.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "BTMATH.ELF")))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script-expect 'btmath: OK' --timeout 300

vgate_assert 01 serial-contains 'btmath: start'
vgate_assert 01 serial-contains 'Bubble Math'
vgate_assert 01 serial-contains '9 + 8 = ?'
vgate_assert 01 serial-contains 'btmath: key 1'
vgate_assert 01 serial-contains 'Correct. +10 points'
vgate_assert 01 serial-contains 'Not quite: 5, not 6.'
vgate_assert 01 serial-contains 'Skipped.'
vgate_assert 01 serial-contains 'Session over. Final score 65.'
vgate_assert 01 serial-contains 'btmath: saved '
vgate_assert 01 serial-contains 'btmath: round played=5 score=65 correct=3 wrong=2'
vgate_assert 01 serial-contains 'btmath: OK'
# The app checks its own results IN the guest and prints the verdict to the
# guest console. No shell, no Unix tool and no host-side script is involved:
# this line is produced by BTMATH.ELF running inside VirelaiOS.
vgate_assert 01 serial-contains 'btmath: selftest begin checks=12'
vgate_assert 01 serial-contains 'btmath: selftest score got=65 want=65 PASS'
vgate_assert 01 serial-contains 'btmath: selftest frame-wrong got=Not quite: 5, not 6. want=present PASS'
vgate_assert 01 serial-contains 'btmath: selftest record-written got=SESSION.TXT want=written PASS'
vgate_assert 01 serial-contains 'btmath: selftest RESULT PASS checks=12 failed=0'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

vgate_assert 01 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "BTMATH", "SESSION.TXT")
got = open(path, "rb").read().decode()
want = "app=BTMATH\nscore=65\nrounds=5\ncorrect=3\nincorrect=2\nseed=7\n"
if not got.startswith(want):
    print("SESSION CONTENT MISMATCH:\ngot          %r\nwant prefix  %r" % (got, want))
    raise SystemExit(1)
print("session verified on the host: %r" % got.replace("\n", " | "))
PY
