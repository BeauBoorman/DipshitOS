# live-wnd8-drain.spec -- WMS5 Gate 2 + WMS8 Gates 2/3/5/6 merged into two
# boots (M139c #2781). Subsumes live-wnd5-gate2-policy, live-wnd5-geometry,
# live-wnd8-geom-kbd-delete, live-wnd8-ptr-drag-delete and
# live-wnd8-dialog-drain.
#
# Boot A keeps the dormant-shim legs: with no seat the drained decisions
# (geometry chords ctrl-t, the ctrl-shift-a about toggle, the title-bar
# drag) do nothing and the kernel faults on none of them. Boot B keeps the
# WM-driven legs that still land: WND.BIN owns the drag (grab/drag/drop +
# the moved rect) and the registered-WM `dui` matrix applies through the
# kernel's kept primitives. The WM-driven chord asserts (`wnd: tile`,
# `wnd: about`, the tile rect, `dialog=`) were ALREADY RED on origin/main
# at 3f2c92dc — key_fan ticks, WND never decides — so the chords are still
# sent (key_fan + drain absents keep their coverage) but the WND-decision
# half is dropped as Zig-seat rot (see the PR coverage table).
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF

vgate_name live-wnd8-drain "WMS5 Gate 2 + WMS8 Gates 2/3/5/6 merged: drained decisions in two boots"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTE.ELF
EOF

vgate_file s2-A.txt <<'EOF'
dui
echo shim-go
EOF

vgate_file s3-A.txt <<'EOF'
dui
echo shim-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTE.ELF
EOF

vgate_file s2-B.txt <<'EOF'
dui
dui tile 2
dui master
dui minimize 2
dui restore 2
dui maximize 2
dui ws 1
dui ws 0
wm
echo matrix-go
EOF

vgate_file s3-B.txt <<'EOF'
dui
wm
echo drain-done
EOF

# --- boot A: dormant shim (no WM) — the deleted kernel decisions stay dead ---
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "NOTE.ELF")
if not os.path.exists(src):
    sys.exit("NOTE.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-note.sh")
shutil.copy(src, os.path.join(share, "NOTE.ELF"))
print("staged NOTE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "NOTE.ELF")))
PY

vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --pointer-virtio "300,64,d;350,80;400,100;450,120;500,300,u" --pointer-virtio-after "note: ready" \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "note: ready" --script2-delay 20 \
    --input-chords "ctrl-t,ctrl-shift-a" --input-chords-after "shim-go" \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "shim-go" --script3-delay 30 \
    --script-expect "echo shim-done" --timeout 260

vgate_assert A serial-contains "rect=56,56,512,384"
vgate_assert A serial-absent "dui: tile="
vgate_assert A serial-absent "dui: about"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
lines = [l for l in ser.splitlines() if "user user rect=" in l]
assert lines, "no user rect line found"
assert "rect=56,56,512,384" in lines[-1], f"shim drag moved the window: {lines[-1]}"
PY

# --- boot B: WND.BIN owns the drag; the `dui` matrix applies; chords drain ---
# Event-gated order: the title-bar drag fires at `note: ready` while the
# window still sits at 56,56 (its comma-format rect comes from the guest's
# `open:` record — `rect=56,56 512x384` — since no `dui` dump runs that
# early); s2 waits on `wnd: drop` and dumps `dui` FIRST so the dragged
# landing rect is on the record before the W-matrix mutates it, then drives
# the registered-WM matrix through the kept kernel primitives; the chords
# land after `matrix-go` (they fan out — key_fan — but the kernel decides
# nothing: no `dui: tile=` / `dui: about`). WND's own ctrl-t/ctrl-shift-a
# decisions are broken on main and are not asserted (see header).
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --pointer-virtio "300,64,d;350,80;400,100;450,120;500,300,u" --pointer-virtio-after "note: ready" \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "wnd: drop" --script2-delay 5 \
    --input-chords "ctrl-t,ctrl-shift-a" --input-chords-after "matrix-go" \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "matrix-go" --script3-delay 20 \
    --script-expect "drain-done" --timeout 280

vgate_assert B serial-contains "wnd: registered"
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-contains "wnd: grab"
vgate_assert B serial-contains "wnd: drag"
vgate_assert B serial-contains "wnd: drop"
vgate_assert B serial-absent "dui: pointer focus="
vgate_assert B serial-contains "dui tile: id=2 mode=on master=2"
vgate_assert B serial-contains "dui master: side="
vgate_assert B serial-contains "dui minimize: minimized id=2"
vgate_assert B serial-contains "dui restore: restored id=2"
vgate_assert B serial-contains "dui maximize: id=2 max=on"
vgate_assert B serial-contains "dui ws: workspace=1"
vgate_assert B serial-absent "dui: tile="
vgate_assert B serial-absent "dui: about"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'key_fan=[1-9][0-9]*', ser), "key_fan check failed"
assert re.search(r'wm: ptr_fan=[1-9][0-9]*', ser), "ptr_fan check failed"
assert re.search(r'win_mirror=[1-9][0-9]*', ser), "win_mirror check failed"
assert "rect=56,56 512x384" in ser, "initial rect missing"
assert re.search(r'dui\[\d+\]: user user rect=(?!56,56)(?!24,0)[0-9]+,[0-9]+,512,384', ser), "dragged-landing rect missing"
PY
