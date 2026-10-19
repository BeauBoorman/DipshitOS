# live-wm1.spec — Lane 1 WM1: eight concurrent pool-backed user windows on VZ.
#
# M78c kept this burst at the measured 16-slot task-pool wall (the pool is
# 64 after M129b / #2611 — the burst now sits well inside it). NOTE.ELF and
# GOTOP.ELF are the only two Go runtimes; SB4DAM.BIN and SEXITEST.BIN replace
# the two retired fixture windows with existing one-window Zig residents. The
# final three windows remain DEVCONS.BIN, RESMON.BIN, and PS.BIN.

vgate_name live-wm1 "Lane 1 WM1: eight concurrent pool-backed user windows on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# One Go runtime uses four M tasks at the compiled default and three at
# GOMAXPROCS=1. Pinning one leaves the measured headroom this eight-window
# burst needs for the two clients.
vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
exec WINLOOP.BIN
exec SB4DAM.BIN
exec SEXITEST.BIN
exec NOTE.ELF
exec GOTOP.ELF
EOF

vgate_file script2.txt <<'EOF'
exec DEVCONS.BIN
exec RESMON.BIN
exec PS.BIN
EOF

vgate_file script3.txt <<'EOF'
dui
syscalls
echo done-wm1-sweep
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, script in (("NOTE.ELF", "build-note.sh"),
                      ("GOTOP.ELF", "build-gotop.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash tools/go/%s"
                 % (name, src, script))
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)"
          % (name, os.path.getsize(os.path.join(share, name))))
PY

vgate_run 01 -- --display --input --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'note: ready' --script3 '$RUN_DIR/script3.txt' --script3-after 'ps: ready' --script-expect 'done-wm1-sweep' --timeout 180

vgate_assert 01 serial-contains 'winloop: open id=2'
vgate_assert 01 serial-contains 'sb4: filled'
vgate_assert 01 serial-contains 'sexitest: ready'
vgate_assert 01 serial-contains 'note: ready'
vgate_assert 01 serial-contains 'top: ready'
vgate_assert 01 serial-contains 'devcons: ready'
vgate_assert 01 serial-contains 'resmon: ready'
vgate_assert 01 serial-contains 'ps: ready'
vgate_assert 01 serial-contains '12 sys_win_open calls=8'
vgate_assert 01 serial-contains 'dui: windows=12 '
vgate_assert 01 serial-count ' user rect=' 8
vgate_assert 01 serial-contains 'done-wm1-sweep'
vgate_assert 01 serial-absent '[EXC] parking:'
