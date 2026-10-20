# live-wnd6-drain.spec -- WMS6 Gates A-E: the five *-drain specs merged into
# two boots (M139c #2781). Every assertion that was still green at 3f2c92dc
# survives here: boot A keeps the dormant-shim legs (wm=none kernel
# decisions: shim alt-tab self-cycle, dock restore, notif corner toggle,
# kernel tray clock, no tooltip on hover); boot B keeps the WM-driven legs
# that still land (WND.BIN dock/notif/alt-tab decisions via the kind-19
# fan-out + slot-65 commands, counters tick, kernel decides nothing). The
# clock-hover tooltip leg was already red on main (`wnd: tooltip` absent for
# the Clock hover) and is not carried; the live-wnd-server run-02 Clock
# probe keeps the text=Clock assert alive.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF

vgate_name live-wnd6-drain "WMS6 Gates A-E merged: dormant-shim + WM-driven drain"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec M21DEMO.BIN
exec NOTE.ELF
EOF

vgate_file s2-A.txt <<'EOF'
dui minimize 2
echo ptr-go
EOF

vgate_file s3-A.txt <<'EOF'
dui
dui notif-center-state
dui tray-state
dui tooltip-state
echo shim-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec M21DEMO.BIN
exec NOTE.ELF
EOF

vgate_file s2-B.txt <<'EOF'
dui minimize 2
clip hello
wm
echo drain-go
EOF

vgate_file s3-B.txt <<'EOF'
wm
dui
dui notif-center-state
dui tray-state
echo drain-done
EOF

# --- boot A: dormant shim (no WM) — every kernel-shim decision in one boot ---
# Order is event-gated: M21DEMO.BIN keeps >=2 cyclable windows up (the shim
# alt-tab self-cycle is a no-op with one window — the same rule WND.BIN
# mirrors in next_alt_tab_target), so the chord fires 5s after
# `m21demo: loop ok` while every window is visible; the minimize lands in s2
# 15s later, then the pointer burst restores it from the dock (focused=2 is
# the last focus change), toggles the notification center on the tray-corner
# click, and ends hovering the clock (the shim still shows no tooltip — the
# dwell decision is deleted).
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
    --input-chords "alt-tab" --input-chords-after "m21demo: loop ok" --input-chords-delay 5 \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "m21demo: loop ok" --script2-delay 20 \
    --pointer-virtio "12,18,c;1240,710,c;1240,700" --pointer-virtio-after "ptr-go" \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "ptr-go" --script3-delay 30 \
    --script-expect "echo shim-done" --timeout 260

vgate_assert A serial-contains "dui minimize: minimized id=2"
vgate_assert A serial-contains "dui notif-center-state: open="
vgate_assert A serial-contains "dui tooltip-state: visible=no"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui: alt-tab (active|cycle)', ser), "shim alt-tab check failed"
assert re.search(r'dui: windows=[0-9]+ focused=2', ser), "dock restore focus check failed"
assert re.search(r'dui tray-state: clock=[0-9][0-9]:[0-9][0-9] clock_set=no', ser), "kernel clock check failed"
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
PY

# --- boot B: WND.BIN owns the drained decisions ---
# The alt-tab chord fires 10s after `m21demo: loop ok`: WND.BIN needs >=2
# cyclable windows (next_alt_tab_target returns null below that, which is
# why a NOTE.ELF-only boot never emits `wnd: alt-tab id=`), and landing it
# before the burst keeps the dock restore the LAST focus change so the
# `focused=2` probe still holds. One pointer burst then covers the surviving
# Gate B/D surfaces: dock-icon hover + click (restores the minimized window
# 2; the dock-label tooltip is the `wnd: tooltip` assert) and the
# tray-corner click (notif-open); s3 probes every state once the center is
# open. The clock hover is gone: its tooltip decision is red on main (see
# header).
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --input-chords "alt-tab" --input-chords-after "m21demo: loop ok" --input-chords-delay 10 \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "m21demo: loop ok" --script2-delay 20 \
    --pointer-virtio "12,24;12,18,c;1240,710,c" --pointer-virtio-after "drain-go" \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "wnd: notif-open" --script3-delay 15 \
    --script-expect "drain-done" --timeout 280

vgate_assert B serial-contains "wnd: dock idx=0"
vgate_assert B serial-contains "wnd: tooltip"
vgate_assert B serial-contains "wnd: notif-open"
vgate_assert B serial-contains "dui notif-center-state: open=yes"
vgate_assert B serial-contains "wnd: alt-tab id="
vgate_assert B serial-absent "dui: alt-tab"
vgate_assert B serial-contains "wnd: tray clock="
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
for counter in ("key_fan", "ptr_fan", "alt_tab", "dock", "notif", "tooltip", "tray"):
    assert re.search(r'%s=[1-9][0-9]*' % counter, ser), counter + " counter check failed"
assert re.search(r'dui: windows=[0-9]+ focused=2', ser), "focused=2 check failed"
assert re.search(r'dui tray-state: clock=[0-9][0-9]:[0-9][0-9] clock_set=yes', ser), "clock_set=yes missing"
assert re.search(r'dui tray-state: .*clip=yes clip_set=yes', ser), "clip=yes check failed"

mclk = re.findall(r'wnd: tray clock=([0-9][0-9]:[0-9][0-9])', ser)
sclk = re.findall(r'dui tray-state: clock=([0-9][0-9]:[0-9][0-9])', ser)
assert mclk and sclk and mclk[-1] == sclk[-1], f"clock mismatch: mclk={mclk} sclk={sclk}"

tray_vals = [int(x) for x in re.findall(r'wm: .*tray=([0-9]+)', ser)]
assert len(tray_vals) >= 2 and tray_vals[-1] > tray_vals[0], f"tray counter did not grow: {tray_vals}"
PY
