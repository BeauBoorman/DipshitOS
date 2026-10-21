# go-drag.spec -- M124a-2 (issue #2677): the guest drag-and-drop adopters
# exercised with a REAL pointer drag on the live seat. GOFILES (the M124a
# #2580 protocol's first source) arms a drag off a pressed row via the ?1002
# button-motion report; the seat owns the ghost and the hit-test from there,
# and the release lands the staged envelope on the opens=-accepting pane.
#
# Shape: go-wm-tabs run 07 (the sash-drag leg) — an explicit live seat
# (wm=none + `exec GOTABWM.ELF`), two client tabs, the ctrl-shift-v split
# cycle, then a --pointer-virtio `d ; move ; u` gesture whose held move
# crosses from GOFILES' left pane onto the target's right pane.
#
#   01  GOFILES + GOEDIT, split v. Press NOTE.TXT (list row 0), held move,
#       release over GOEDIT: `drag arm` / `drag over accept=1` /
#       `drag drop` seat-side, `goedit: drop text/plain n=` and
#       `gofiles: drag end delivered` app-side.
#   02  GOFILES + GOVIEW, same gesture on PIC.PNG: the image/png envelope
#       decodes through the same DecodeImage as a file load
#       (`gview: drop image/png 160x120 bytes=`).
#
# Geometry: SplitVert tiles 0..640 / 640..1280 edge-to-edge (unset sash has
# no gutter) and the hosted window starts at RailHeight=22 — observed on
# the first gate run: a scanout-y press maps to SGR row (y-22)/16+1.
# GOFILES' two chrome rows occupy cells 0-1, so list row 0 (NOTE.TXT)
# centres near y=62 and row 1 (PIC.PNG) near y=78; the release point
# (900,360) sits mid-pane on the right. The press/motion samples stay
# inside the left pane so the ?1002 report reaches GOFILES; once
# BeginDrag acks the seat owns every later sample. The samples pace at
# 2.5 s per step and the first gate run showed the synchronous BeginDrag
# RPC landing within a hair of the release edge — the extra held moves
# between the arming motion and the release exist purely to give that
# RPC wall-clock headroom (pre-arm moves just forward to the pressed
# window as more ?1002 reports).
#
# exec-order: assert-proven -- each run ends on the app's own
# `gofiles: drag end delivered` receipt (the expect is guest output, not
# a script echo); a drag that never armed, never delivered, or was
# refused can never reach it.

vgate_name go-drag "M124a-2 #2677: GOFILES drags a file onto GOEDIT (text/plain splice) and GOVIEW (image/png decode) through the seat's drag session"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-01.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

# The second app's exec rides script3 so it is issued only after
# `gofiles: ready` — i.e. after GOFILES' window has opened; an
# unsequenced pair races (the first gate run put GOVIEW on the left),
# so this staging pins GOFILES to tab 0 deterministically. M137a
# (#2846) re-contracted pane assignment — the focused tab takes child A
# (the left/top pane) and the next unplaced tab takes B, where the
# pre-M137a seat assigned panes in window-open order — so the chord
# batch leads with ctrl-1 to focus GOFILES before the split. GOFILES
# lands on the left under BOTH contracts (it is also strip index 0).
vgate_file script2-01.txt <<'EOF'
dui focus 0
exec GOFILES.ELF /host/DRAG
EOF

vgate_file script3-01.txt <<'EOF'
exec GOEDIT.ELF
EOF

vgate_file script-02.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
dui focus 0
exec GOFILES.ELF /host/DRAG
EOF

vgate_file script3-02.txt <<'EOF'
exec GOVIEW.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for elf, build in (("GOTABWM.ELF", "tools/go/build-gotabwm.sh"),
                   ("GOFILES.ELF", "tools/go/build-files.sh"),
                   ("GOEDIT.ELF", "tools/go/build-goedit.sh"),
                   ("GOVIEW.ELF", "tools/go/build-goview.sh")):
    src = os.path.join(".build", "go", elf)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash %s"
                 % (elf, src, build))
    shutil.copy(src, os.path.join(share, elf))
# The drag fixtures: exactly two files, name-sorted NOTE.TXT then PIC.PNG —
# list rows 0 and 1. NOTE.TXT is 8 bytes so `n=` pins the splice length;
# PIC.PNG is the repo's own 160x120 decoder fixture so the viewer's drop
# path is the decode path, not a synthetic.
drag = os.path.join(share, "DRAG")
os.makedirs(drag, exist_ok=True)
with open(os.path.join(drag, "NOTE.TXT"), "w") as f:
    f.write("drag-me\n")
png = os.path.join("tests", "fixtures", "png", "viewer_160x120.png")
if not os.path.exists(png):
    sys.exit("PNG fixture missing (expected " + png + ")")
shutil.copy(png, os.path.join(drag, "PIC.PNG"))
# Explicit opt-in, same as go-wm-tabs: the compiled default is already the
# Go seat (M59). Seed wm=none so this boot proves the drag on an executed
# GOTABWM, not the autostart path.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("staged GOTABWM/GOFILES/GOEDIT/GOVIEW + DRAG/{NOTE.TXT,PIC.PNG}")
PY

# --- run 01: text/plain onto GOEDIT ----------------------------------------
# The gesture is one drag: press on NOTE.TXT's row (x=40, y=62 — cell row 2,
# the first list entry), a held move to (200,200) still inside the left pane
# (the ?1002 report that arms the source), then release mid-right-pane. The
# seat's kind-24 arm validated the staged envelope; the release hit-tests
# GOEDIT (opens=text,binary accepts text/plain) and delivers.
vgate_run 01 -- \
    --screen '$RUN_DIR/drag-edit-screen' \
    --via-virtio \
    --script '$RUN_DIR/script-01.txt' \
    --script2 '$RUN_DIR/script2-01.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-1,ctrl-shift-v' \
    --input-chords-after 'gotabwm: rail n=2' \
    --pointer-virtio '40,62,d;200,200;320,240;480,280;900,360,u' \
    --pointer-virtio-after 'gotabwm: split v' \
    --script3 '$RUN_DIR/script3-01.txt' \
    --script3-after 'gofiles: ready' \
    --script-expect 'gofiles: drag end delivered' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: settings wm=none'
vgate_assert 01 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 01 serial-contains 'gofiles: declare accepted'
vgate_assert 01 serial-contains 'gofiles: list /host/DRAG n=2'
vgate_assert 01 serial-contains 'gofiles: entry NOTE.TXT file'
vgate_assert 01 serial-contains 'gofiles: entry PIC.PNG file'
vgate_assert 01 serial-contains 'gofiles: ready'
vgate_assert 01 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 01 serial-contains 'goedit: present'

# The split: two live panes edge-to-edge before the gesture starts.
vgate_assert 01 serial-contains 'gotabwm: split v'
vgate_assert 01 serial-contains 'x=640 y=0 w=640 h=720'

# The source's half: the app armed off the held move and named its payload.
vgate_assert 01 serial-contains 'gofiles: drag arm NOTE.TXT text/plain len=8'
vgate_assert 01 serial-contains 'gotabwm: drag arm id='
vgate_assert 01 serial-contains ' mime=text/plain len=8'

# The seat's half: the hover accepted and the release delivered.
vgate_assert 01 serial-contains 'gotabwm: drag over id='
vgate_assert 01 serial-contains 'accept=1'
vgate_assert 01 serial-contains 'gotabwm: drag drop id='
vgate_assert 01 serial-contains ' mime=text/plain'

# The target's half: the payload spliced through the paste path.
vgate_assert 01 serial-contains 'goedit: drop text/plain n=8'
vgate_assert 01 serial-contains 'gofiles: drag end delivered win='

# The refusals that must NOT happen: no arm refusal, no cancel, no app-side
# refusal marker, no pended open firing as a second click (the gesture stole
# it — `open file` would mean releaseClick ran openSel).
vgate_assert 01 serial-absent 'gotabwm: drag refuse'
vgate_assert 01 serial-absent 'gotabwm: drag cancel'
vgate_assert 01 serial-absent 'gofiles: drag refused'
vgate_assert 01 serial-absent 'gofiles: open file NOTE.TXT'
vgate_assert 01 serial-absent 'goedit: drop no-payload'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The ordering is the proof, but only where drag.go pins one: the seat's
# own markers order arm -> drop in its stream; the drop's Seq=0 target
# notice posts BEFORE the `drag drop` marker and the source's Seq=1
# receipt posts AFTER it, while each app drains its own queue on its own
# M — splice vs receipt is a byte race, not a contract (the M121e rule;
# same anchoring as go-dogfood boot 08).
vgate_assert 01 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def first(prefix, start=0):
    for i in range(start, len(ser)):
        if prefix in ser[i]:
            return i
    sys.exit("missing " + prefix)
arm = first("gotabwm: drag arm id=")
src = first("gofiles: drag arm NOTE.TXT")
drop = first("gotabwm: drag drop id=")
splice = first("goedit: drop text/plain")
receipt = first("gofiles: drag end delivered")
if not (arm < drop and arm < splice and drop < receipt):
    sys.exit("order arm@%d drop@%d splice@%d receipt@%d (src@%d)" % (
        arm, drop, splice, receipt, src))
print("drag ordering: seat-arm@%d src-arm@%d seat-drop@%d splice@%d receipt@%d"
      % (arm, src, drop, splice, receipt))
PY

# --- run 02: image/png onto GOVIEW -----------------------------------------
# Identical shape, one row lower: press PIC.PNG (list row 1, y=78) and
# release over GOVIEW (opens=image). The viewer's DropTarget decodes the
# envelope's bytes — `drop image/png 160x120 bytes=` is the whole proof.
vgate_run 02 -- \
    --screen '$RUN_DIR/drag-view-screen' \
    --via-virtio \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-1,ctrl-shift-v' \
    --input-chords-after 'gotabwm: rail n=2' \
    --pointer-virtio '40,78,d;200,200;320,240;480,280;900,360,u' \
    --pointer-virtio-after 'gotabwm: split v' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'gofiles: ready' \
    --script-expect 'gofiles: drag end delivered' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 02 serial-contains 'gofiles: list /host/DRAG n=2'
vgate_assert 02 serial-contains 'exec: loaded GOVIEW.ELF'
vgate_assert 02 serial-contains 'gview: empty (no args)'
vgate_assert 02 serial-contains 'gotabwm: split v'
vgate_assert 02 serial-contains 'gofiles: drag arm PIC.PNG image/png'
vgate_assert 02 serial-contains 'gotabwm: drag arm id='
vgate_assert 02 serial-contains ' mime=image/png'
vgate_assert 02 serial-contains 'gotabwm: drag over id='
vgate_assert 02 serial-contains 'accept=1'
vgate_assert 02 serial-contains 'gotabwm: drag drop id='
vgate_assert 02 serial-contains ' mime=image/png'
vgate_assert 02 serial-contains 'gview: drop image/png 160x120 bytes='
vgate_assert 02 serial-contains 'gofiles: drag end delivered win='
vgate_assert 02 serial-absent 'gotabwm: drag refuse'
vgate_assert 02 serial-absent 'gotabwm: drag cancel'
vgate_assert 02 serial-absent 'gofiles: drag refused'
vgate_assert 02 serial-absent 'gview: drop unsupported'
vgate_assert 02 serial-absent 'gview: drop decode'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# --- M124e (#2584): the seat-owned primary selection -------------------------
# Runs 03/04 are the card's seat leg: select in one app -> middle-click in
# another pastes, gated by the manifest's `selection=primary` on BOTH ends.
#
#   03  GOEDIT /host/SEL.TXT, ctrl-a selects all -> `goedit: selpub` +
#       `gotabwm: sel pub`; then GOTERM opens and a middle-click inside its
#       pane stages the buffer at GOTERM's rendezvous and notices it —
#       `gotabwm: sel paste` + `goterm: sel-paste`, and the pasted line
#       (which ends in a newline) submits: `goterm: line echo sel-live-ok`.
#   04  Same boot shape, but the middle-click target is GOFILES — its
#       manifest row has no `selection=` cap. GOEDIT's publish still
#       lands (the buffer fills), then the click is refused by name
#       (`paste cap`) and no notice is ever posted: no `sel paste`, no
#       `gofiles: sel-paste`. The shipped manifest itself is the
#       fixture — one app opted in, one not.
#
# Geometry: no split is needed — GOTERM's declare proposes the full
# viewport, so (640,400) sits inside its pane. The middle click rides the
# `mc` pointer-virtio step (buttons bit2, this card's runner grammar).

vgate_file script-03.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-03.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF /host/SEL.TXT
EOF

vgate_file script3-03.txt <<'EOF'
exec GOTERM.ELF
EOF

vgate_file script-04.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-04.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF /host/SEL.TXT
EOF

vgate_file script3-04.txt <<'EOF'
exec GOFILES.ELF /host/DRAG
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for elf, build in (("GOTERM.ELF", "tools/go/build-goterm.sh"),
                   ("GOFILES.ELF", "tools/go/build-files.sh")):
    src = os.path.join(".build", "go", elf)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash %s"
                 % (elf, src, build))
    shutil.copy(src, os.path.join(share, elf))
# The selection fixture: its tail newline means a paste into GOTERM's line
# editor SUBMITS — `goterm: line echo sel-live-ok` is the end-to-end proof
# the bytes reached the shell, not just a buffer.
with open(os.path.join(share, "SEL.TXT"), "w") as f:
    f.write("echo sel-live-ok\n")
print("staged GOTERM/GOFILES + SEL.TXT")
PY

# --- run 03: select in GOEDIT -> middle-click in GOTERM pastes ---------------
# The chords fire after `goedit: present` (its event loop is live), the term
# opens after the publish marker (ordering, not a race), and the middle click
# waits on GOTERM's ready so its binding exists before the seat delivers.
vgate_run 03 -- \
    --screen '$RUN_DIR/sel-screen' \
    --via-virtio \
    --script '$RUN_DIR/script-03.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-a' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'goedit: selpub n=17' \
    --pointer-virtio '640,400,mc' \
    --pointer-virtio-after 'goterm: ready' \
    --script-expect 'goterm: done status=0' --timeout 300

vgate_assert 03 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 03 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 03 serial-contains 'goedit: selpub n=17'
vgate_assert 03 serial-contains 'gotabwm: sel pub id='
vgate_assert 03 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 03 serial-contains 'goterm: ready'
vgate_assert 03 serial-contains 'gotabwm: sel paste id='
vgate_assert 03 serial-contains ' len=17'
vgate_assert 03 serial-contains 'goterm: sel-paste n=17'
vgate_assert 03 serial-contains 'goterm: line echo sel-live-ok'
vgate_assert 03 serial-contains 'goterm: done status=0'
vgate_assert 03 serial-absent 'gotabwm: sel refuse'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# The ordering is the proof: publish -> delivery notice -> app consume ->
# line submitted.
vgate_assert 03 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def first(prefix):
    for i, l in enumerate(ser):
        if prefix in l:
            return i
    sys.exit("missing " + prefix)
pub = first("gotabwm: sel pub id=")
paste = first("gotabwm: sel paste id=")
take = first("goterm: sel-paste")
line = first("goterm: line echo sel-live-ok")
if not (pub < paste < take < line):
    sys.exit("order pub@%d paste@%d take@%d line@%d" % (pub, paste, take, line))
print("sel ordering: pub@%d paste@%d take@%d line@%d" % (pub, paste, take, line))
PY

# --- run 04: the cap is the gate ----------------------------------------------
# Same boot shape, but the target is GOFILES — its manifest row has no
# selection= cap. GOEDIT's publish still lands (the buffer fills), then the
# middle-click inside GOFILES' pane is refused by name (`paste cap`) and no
# notice is ever posted. The shipped manifest itself is the fixture: one app
# opted in, one not.
vgate_run 04 -- \
    --screen '$RUN_DIR/sel-nocap-screen' \
    --via-virtio \
    --script '$RUN_DIR/script-04.txt' \
    --script2 '$RUN_DIR/script2-04.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-a' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-04.txt' \
    --script3-after 'goedit: selpub n=17' \
    --pointer-virtio '640,400,mc' \
    --pointer-virtio-after 'gofiles: ready' \
    --script-expect 'gotabwm: sel refuse' --timeout 300

vgate_assert 04 serial-contains 'goedit: present'
vgate_assert 04 serial-contains 'goedit: selpub n=17'
vgate_assert 04 serial-contains 'gotabwm: sel pub id='
vgate_assert 04 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 04 serial-contains 'gofiles: ready'
vgate_assert 04 serial-contains 'gotabwm: sel refuse'
vgate_assert 04 serial-contains ' paste cap'
vgate_assert 04 serial-absent 'gotabwm: sel paste id='
vgate_assert 04 serial-absent 'gofiles: sel-paste'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
