# go-menubar.spec -- M190d (#3239): the GOFILES menu leg of the menubar
# adoption sweep. The GOFILES bar shares row 0 with the path bar (a VT
# degrade of appkit.MenuBar — the same state machine the canvas apps
# draw); F10 reaches it as ESC[21~ over the bound tty, and an open menu
# plates over the frame like the M124d context menu.
#
# This leg lives here and not in go-fileman.spec because that file was
# held by another active claim at claim time (#3256); the leg's content is
# the card's own: open a menu, activate a row, the verb's existing marker
# fires.
vgate_name go-menubar "M190d #3239: GOFILES menubar — F10 engages, File menu opens, Quick Look fires the spacebar verb's marker"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOFS'
tabwm
tabwm start
EOFS

vgate_file script2.txt <<'EOFS'
exec GOFILES.ELF /host/FM
EOFS

vgate_file script3.txt <<'EOFS'
dui close 2
echo rx-menubar-ok
EOFS

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOFILES.ELF")
if not os.path.exists(src):
    sys.exit("GOFILES.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-files.sh")
shutil.copy(src, os.path.join(share, "GOFILES.ELF"))
fm = os.path.join(share, "FM")
os.makedirs(fm, exist_ok=True)
with open(os.path.join(fm, "LOOK.TXT"), "wb") as f:
    f.write(b"quicklook me\n")
print("staged GOFILES.ELF + FM/LOOK.TXT")
PY

# File menu: Open(0), Open With(1), Quick Look(2) — f10 engages, down
# opens with hover on Open, down down reaches Quick Look, return fires the
# spacebar verb: its own `gofiles: quicklook` marker answers.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'down,f10,down,down,down,return' \
    --input-chords-after 'gofiles: present' \
    --script3 '$RUN_DIR/script3.txt' --script3-after 'gofiles: quicklook ' \
    --script-expect 'rx-menubar-ok' --timeout 240

vgate_assert 01 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 01 serial-contains 'gofiles: menubar open File'
vgate_assert 01 serial-contains 'gofiles: menubar Quick Look'
vgate_assert 01 serial-contains 'gofiles: quicklook '
vgate_assert 01 serial-contains 'rx-menubar-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
