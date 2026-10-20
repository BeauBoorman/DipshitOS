# go-paint.spec -- M141a (issue #2787): GOPAINT.ELF on the draw-v2 canvas.
#
# Three legs, two boot shapes — driven by the kernel's own input rules:
#
#   01  SHIM (no seat): the kernel hit-tests every pointer sample and pushes
#       MOUSE_* to the window in LOCAL coords (the go-calc pad-leg shape — a
#       seat's content forward is terminal-only, so canvas apps under GOTABWM
#       never see the pointer). A scripted gesture set exercises all five
#       tools; ctrl-z twice reverts the newest two ops; ctrl-s raises the
#       save picker, a typed name lands /host/PAINT1.QOI, and a second exec
#       reopens it — every hop pinned by the app's own sum= digests, the
#       pixel probe, and the file's host-verified SHA-256.
#   02  SEAT (GOTABWM): the M124a drag — GOFILES arms PIC.QOI, the release
#       lands on GOPAINT's split pane, the in-app confirm answers the
#       staged payload, and the canvas becomes the image. GOPAINT has no
#       APPS.TXT row in the repo manifest (M132b reserved grants only), so
#       this leg stages one on the gate's own share — the same seam
#       go-fileman run 13 uses for its MISSING.ELF refusal row.
#   03  SEAT: M125a state — tool rect, ctrl-shift-w closes (the seat
#       collects the blob), ctrl-shift-t reopens the recorded bin, and the
#       restored app reloads the file and the tool selection.
#
# Geometry (run 01): the window opens at (24,24), 832x600. The document's
# window-local origin is (64,32); everything interactive sits at local
# y >= 28, clear of the kernel's 16px title band (a press inside it drags
# the WINDOW, it does not deliver). Pointer digits below are SCANOUT coords
# (local + 24,24). Palette cell i sits at (8 + (i%4)*13, 200 + (i/4)*13) with
# an 11px tile.
#
#   palette 9   (orange)    local (26,231)   -> scanout (50,255)
#   brush L                  doc (40,40)->(120,40)->(120,100)
#                            -> scanout (128,96)->(208,96)->(208,156)
#   line button              local (28,65)   -> scanout (52,89)
#   line drag                doc (240,40)->(300,140)
#                            -> scanout (328,96)->(388,196)
#   rect button              local (28,91)   -> scanout (52,115)
#   rect drag                doc (100,80)->(220,180)
#                            -> scanout (188,136)->(308,236)
#   palette 11  (green)      local (52,231)  -> scanout (76,255)
#   fill button              local (28,117)  -> scanout (52,141)
#   fill click (rect inside) doc (160,120)   -> scanout (248,176)
#   erase button             local (28,143)  -> scanout (52,167)
#   erase drag               doc (220,90)->(320,90)  (cuts the line)
#                            -> scanout (308,146)->(408,146)
#
# Every sum=/probe value below is pinned in class-A too: gatevec_test.go's
# gateGesture replays this exact sequence and asserts the same digests, so
# the spec's literals cannot drift from the implementation.
#
# HOST PREREQUISITE (the setup hook fails honestly when missing):
#   bash tools/go/build-gopaint.sh   ->  .build/go/GOPAINT.ELF
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF  (runs 02-03)
#   bash tools/go/build-files.sh     ->  .build/go/GOFILES.ELF  (run 02)

vgate_name go-paint "M141a #2787: GOPAINT.ELF — 5 tools, 16-color palette, bounded fill, 16-step undo, QOI save/open, confirmed drop-in, save_state"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# --- run 01: shim-mode draw / undo / save / reopen --------------------------

vgate_file script-01.txt <<'EOF'
exec GOPAINT.ELF
EOF

vgate_file script2-01.txt <<'EOF'
exec GOPAINT.ELF /host/PAINT1.QOI
EOF

vgate_file script3-01.txt <<'EOF'
echo rx-go-paint-ok
EOF

# --- run 02: the seat-mediated drop -----------------------------------------

vgate_file script-02.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
dui focus 0
exec GOFILES.ELF /host/DROP
EOF

vgate_file script3-02.txt <<'EOF'
exec GOPAINT.ELF
EOF

# --- run 03: close -> reopen -> restored state -------------------------------

vgate_file script-03.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-03.txt <<'EOF'
dui focus 0
exec GOPAINT.ELF /host/DROP/SEED.QOI
EOF

vgate_file script3-03.txt <<'EOF'
echo rx-go-paint-state-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for elf, build in (("GOPAINT.ELF", "tools/go/build-gopaint.sh"),
                   ("GOTABWM.ELF", "tools/go/build-gotabwm.sh"),
                   ("GOFILES.ELF", "tools/go/build-files.sh")):
    src = os.path.join(".build", "go", elf)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash %s"
                 % (elf, src, build))
    shutil.copy(src, os.path.join(share, elf))
# The drop + restore fixture: the repo's own 160x120 QOI decoder fixture —
# well under the 64 KiB drag-envelope bound — staged once, named twice so
# run 03's restore leg can own its path.
drop = os.path.join(share, "DROP")
os.makedirs(drop, exist_ok=True)
qoi = os.path.join("tests", "fixtures", "qoi", "viewer_160x120.qoi")
if not os.path.exists(qoi):
    sys.exit("QOI fixture missing (expected " + qoi + ")")
shutil.copy(qoi, os.path.join(drop, "PIC.QOI"))
shutil.copy(qoi, os.path.join(drop, "SEED.QOI"))
# GOPAINT has no manifest row in the repo's image/apps.txt (M132b reserved
# the grant line only); the seat's drag admission reads opens= from the
# SHARE's APPS.TXT, so append the row here — the go-fileman run-13
# MISSING.ELF precedent, one gate-local line, never upstreamed.
apps = os.path.join(share, "APPS.TXT")
with open(apps) as f:
    body = f.read()
if "GOPAINT.ELF" not in body:
    if not body.endswith("\n"):
        body += "\n"
    body += "GOPAINT.ELF | Paint | P | dock=false | v=2 | opens=image\n"
    with open(apps, "w") as f:
        f.write(body)
# Runs 02/03 exec the seat explicitly; keep the autostart off (wm=none) so
# the boot proves the exec'd seat, and run 01 stays the bare shim.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("staged GOPAINT/GOTABWM/GOFILES + DROP/{PIC,SEED}.QOI + APPS.TXT row")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/paint-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script-01.txt' \
    --pointer-virtio '50,255,d;50,255,u;128,96,d;208,96;208,156;208,156,u;52,89,d;52,89,u;328,96,d;388,196;388,196,u;52,115,d;52,115,u;188,136,d;308,236;308,236,u;76,255,d;76,255,u;52,141,d;52,141,u;248,176,d;248,176,u;52,167,d;52,167,u;308,146,d;408,146;408,146,u' \
    --pointer-virtio-after 'gopaint: ready' \
    --input-chords 'ctrl-z,ctrl-z,ctrl-s' \
    --input-chords-after 'gopaint: commit erase' \
    --input-string $'PAINT1.QOI\n' \
    --input-string-after 'gopaint: pick save' \
    --script2 '$RUN_DIR/script2-01.txt' \
    --script2-after 'gopaint: saved ' \
    --script3 '$RUN_DIR/script3-01.txt' \
    --script3-after 'gopaint: loaded ' \
    --script-expect 'rx-go-paint-ok' --timeout 420

vgate_assert 01 serial-contains 'exec: loaded GOPAINT.ELF'
vgate_assert 01 serial-contains 'gopaint: open id='
vgate_assert 01 serial-contains 'gopaint: not-tab-aware'
vgate_assert 01 serial-contains 'gopaint: canvas 640x480'
vgate_assert 01 serial-contains 'gopaint: ready'

# The gesture set — every commit carries its touched count and canvas digest.
vgate_assert 01 serial-contains 'gopaint: color 9'
vgate_assert 01 serial-contains 'gopaint: commit brush n=710 sum=5c81f313b5e994e1'
vgate_assert 01 serial-contains 'gopaint: tool line'
vgate_assert 01 serial-contains 'gopaint: commit line n=513 sum=7b8f7c510a15d763'
vgate_assert 01 serial-contains 'gopaint: commit rect n=440 sum=84b28dfa95fb6f29'
vgate_assert 01 serial-contains 'gopaint: color 11'
vgate_assert 01 serial-contains 'gopaint: commit fill n=11677 sum=5b5a7eeede3e7cdb'
vgate_assert 01 serial-contains 'gopaint: commit erase n=513 sum=1736b82007e7fe87'

# Undo twice: the erase reverts (line restored), then the fill — the probe
# pixel returns to paper and the digest to the post-rect value.
vgate_assert 01 serial-contains 'gopaint: undo depth=4 sum=5b5a7eeede3e7cdb probe=0xff00e436'
vgate_assert 01 serial-contains 'gopaint: undo depth=3 sum=84b28dfa95fb6f29 probe=0xfffff1e8'

# Save through the picker, then a second exec reopens the file: the reopened
# canvas digest equals the post-undo one — "reopen gets the same pixels back".
vgate_assert 01 serial-contains 'gopaint: pick save /host/PAINT1.QOI'
vgate_assert 01 serial-contains 'gopaint: saved /host/PAINT1.QOI n=6042 sum=84b28dfa95fb6f29'
vgate_assert 01 serial-contains 'gopaint: loaded /host/PAINT1.QOI 640x480 sum=84b28dfa95fb6f29'
vgate_assert 01 serial-contains 'rx-go-paint-ok'

vgate_assert 01 serial-absent 'gopaint: open refused'
vgate_assert 01 serial-absent 'gopaint: save refused'
vgate_assert 01 serial-absent 'gopaint: undo empty'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The file on the share: SHA-256 of the actual saved bytes plus a QOI decode
# probing two pixels — the filled rect interior is green (palette 11) and the
# probe point the undo restored is paper.
vgate_assert 01 python <<'PY'
import hashlib, os
share = os.environ["VG_SHARE"]
data = open(os.path.join(share, "PAINT1.QOI"), "rb").read()
sha = hashlib.sha256(data).hexdigest()
assert sha == "7a49b337e2f459a9aabe99ee927f353c3634afa42c8ce0ab136178e19b98c3bd", \
    "PAINT1.QOI sha256 %s" % sha
assert data[:4] == b"qoif", "not a QOI"
w = int.from_bytes(data[4:8], "big")
h = int.from_bytes(data[8:12], "big")
assert (w, h) == (640, 480), "dims %dx%d" % (w, h)
print("PAINT1.QOI: %d bytes sha256=%s %dx%d" % (len(data), sha[:12], w, h))
PY

# --- run 02: the seat drop ----------------------------------------------------
# go-drag run 02's shape with GOPAINT as the target: press PIC.QOI's row,
# a held move through the split, release mid-right-pane; the seat's opens=
# admission reads the staged APPS.TXT row, the target's confirm dialog
# answers, and the canvas becomes the image.
vgate_run 02 -- \
    --screen '$RUN_DIR/paint-drop-screen' \
    --via-virtio \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-v' \
    --input-chords-after 'gotabwm: rail n=2' \
    --pointer-virtio '40,62,d;200,200;320,240;480,280;900,360,u' \
    --pointer-virtio-after 'gotabwm: split v' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'gofiles: ready' \
    --input-string $'\t\n' \
    --input-string-after 'gopaint: drop-confirm' \
    --script-expect 'gopaint: drop image/qoi 160x120' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 02 serial-contains 'gofiles: ready'
vgate_assert 02 serial-contains 'exec: loaded GOPAINT.ELF'
vgate_assert 02 serial-contains 'gopaint: ready'

vgate_assert 02 serial-contains 'gotabwm: split v'
vgate_assert 02 serial-contains 'gofiles: drag arm PIC.QOI image/qoi'
vgate_assert 02 serial-contains 'gotabwm: drag over id='
vgate_assert 02 serial-contains 'accept=1'
vgate_assert 02 serial-contains 'gotabwm: drag drop id='

# The confirm gated the replace: dialog raised, the typed Tab+Return chose
# Yes, and the canvas is the dropped raster.
vgate_assert 02 serial-contains 'gopaint: drop-confirm'
vgate_assert 02 serial-contains 'gopaint: drop image/qoi 160x120 sum=9ea88033bfdfe325'

vgate_assert 02 serial-absent 'gopaint: drop refused'
vgate_assert 02 serial-absent 'gopaint: drop cancel'
vgate_assert 02 serial-absent 'gotabwm: drag refuse'
vgate_assert 02 serial-absent 'gotabwm: drag cancel'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# --- run 03: save_state through close + reopen -------------------------------
# 'r' selects the rect tool (keys reach the focused app under the seat even
# though the pointer never does), ctrl-shift-w closes the tab — the seat
# collects the blob first — and ctrl-shift-t re-execs the recorded bin.
vgate_run 03 -- \
    --screen '$RUN_DIR/paint-state-screen' \
    --via-virtio \
    --script '$RUN_DIR/script-03.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'r,ctrl-shift-w,ctrl-shift-t' \
    --input-chords-after 'gopaint: ready' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'gopaint: state restored' \
    --script-expect 'rx-go-paint-state-ok' --timeout 300

vgate_assert 03 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 03 serial-contains 'exec: loaded GOPAINT.ELF'
vgate_assert 03 serial-contains 'gopaint: loaded /host/DROP/SEED.QOI 160x120'
vgate_assert 03 serial-contains 'gopaint: tool rect'
vgate_assert 03 serial-contains 'gotabwm: tab close id='
vgate_assert 03 serial-contains 'gotabwm: reopen GOPAINT.ELF'
vgate_assert 03 serial-contains 'gopaint: state restored file=/host/DROP/SEED.QOI tool=rect'
vgate_assert 03 serial-contains 'rx-go-paint-state-ok'
vgate_assert 03 serial-absent 'gopaint: state stale'
vgate_assert 03 serial-absent 'gopaint: open refused'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
