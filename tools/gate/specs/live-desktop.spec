# live-desktop.spec — desktop platform, launcher, hosted app, and input on VZ.
#
# M78c retires the old Zig launcher. GOTABWM.ELF is the shipping Go seat and
# APPS.TXT launcher; Ctrl+Space + a typed filter + Enter exercises its
# manifest read, sys_exec path, hosted-client declare, input routing, close,
# and teardown. The typed NOTE.ELF path lives in live-desktop-typing.

vgate_name live-desktop "desktop platform, Go launcher, hosted app, and input on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
exec GOTABWM.ELF
EOF

vgate_file script2.txt <<'EOF'
dui focus 0
EOF

vgate_file script3.txt <<'EOF'
procs
syscalls
echo done-desktop-sweep
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, script in (("GOTABWM.ELF", "build-gotabwm.sh"),
                      ("GOCALC.ELF", "build-gocalc.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash tools/go/%s"
                 % (name, src, script))
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)"
          % (name, os.path.getsize(os.path.join(share, name))))
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
# M79a made the close choreography demo-only, armed by the trigger's
# presence — the gate's host close/done contract needs it seeded.
with open(os.path.join(share, "GOTABWM.DEMO"), "w") as f:
    f.write("demo\n")
print("seeded SETTINGS.TXT (explicit GOTABWM launch) + GOTABWM.DEMO")
PY

vgate_run A -- \
    --display --input --screen '$RUN_DIR/gpu-screen' --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-space,c,a,l,c,return' \
    --input-chords-after 'gotabwm: present' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gotabwm: host done' \
    --script-expect 'done-desktop-sweep' \
    --timeout 300

vgate_assert A serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert A serial-contains 'gotabwm: registered'
vgate_assert A serial-contains 'gotabwm: present'
vgate_assert A serial-contains 'gotabwm: key'
vgate_assert A serial-contains 'gotabwm: launcher open n='
vgate_assert A serial-contains 'gotabwm: launcher filter q=calc n=1'
vgate_assert A serial-contains 'gotabwm: launcher exec GOCALC.ELF'
vgate_assert A serial-contains 'gocalc: declare accepted'
vgate_assert A serial-contains 'gocalc: present'
vgate_assert A serial-contains 'gotabwm: host close id='
vgate_assert A serial-contains 'gotabwm: host done'
vgate_assert A serial-contains '28 sys_exec calls=1'
vgate_assert A serial-contains 'done-desktop-sweep'
vgate_assert A serial-absent '[EXC] parking:'
