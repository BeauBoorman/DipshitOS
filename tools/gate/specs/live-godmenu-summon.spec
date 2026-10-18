# live-godmenu-summon.spec -- M37 DQ1 God Menu summon + dynamic apps (issue #836)
# M66c (#1445 retarget, #1485 retirement): the client is NOTE.ELF, the Go
# successor to the Zig notepad, and the Zig binary itself is now GONE. The
# lifecycle vocabulary is shared by design (`note:` mirrors `notepad:`), so the
# assertions below moved by prefix alone. The coverage that app alone had moved
# to GOEDIT.ELF (find/goto, the unsaved-decline contract) or GOCOMP.ELF (its
# clipboard+timer composition); the theme-token boots were retired with it.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF

vgate_name live-godmenu-summon "M37 DQ1 God Menu summon + dynamic apps"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
wnd start
exec NOTE.ELF
EOF

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
    --input-chords "ctrl-space,c,a,l,c,return,escape" --input-chords-after "note: ready" \
    --script-expect "wnd: god-menu exec verb=gocalc" --timeout 180

vgate_assert A serial-contains "wnd: god-menu open"
vgate_assert A serial-contains "wnd: god-menu exec verb=gocalc"
vgate_assert A serial-contains "wnd: god-menu close"
vgate_assert A serial-absent "[EXC] parking:"

vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
m = re.search(r'wnd: god-menu apps=([0-9]+)', ser)
assert m, "apps marker missing"
n = int(m.group(1))
# The bound is "the dynamic catalog loaded", not a pinned row count —
# it drifts with APPS.TXT (19 rows now, 8 dock=true, menu_apps_max=16).
assert n >= 1, f"dynamic apps count {n}: catalog failed to load"
PY
