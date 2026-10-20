# live-image-viewer.spec -- M36 IMG5 raster viewer on VZ, RETARGETED by M71h
# (#1567) onto GOVIEW.ELF, the Go successor to Zig VIEW.BIN (deleted with
# user/src/view.zig in the same card).
#
# Five boots, all on the shim compositor (this spec stages no GOTABWM.ELF, so
# `wm: autostart` falls back and the viewer honestly reports
# `gview: not-tab-aware (shim or WND desktop)`; the seat's own hosting of the
# same declare is go-wm-seat run 04):
#
#   QOI   -- the happy path. The fixture decodes through webrender's in-tree QOI
#            decoder (D1: reuse, do not vendor a second decoder), reaches the
#            screen, and the old gate's key burst still drives it: zoom table up
#            to 800%, arrow panning (which only MOVES once the image is bigger
#            than the viewport, hence six zoom-ins rather than the old three --
#            the window is the same 328x264, so the burst had to grow, not the
#            assertions shrink), reset to 100%, one step down to 66%, then `q`
#            exits 43.
#   PNG   -- decode, formerly a gap. This leg originally asserted
#            `gview: unsupported PNG` + `loaded` ABSENT because the guest
#            build had no PNG decoder (stdlib image/png drags in
#            compress/zlib -> fmt -> os). M93e landed the bounded in-tree
#            decoder (image_png_guest.go -> DecodePNG), so the app now
#            loads the fixture; the assertions below pin that success and
#            still prove the IHDR sniff sizes the window BEFORE the decode
#            (the `open` marker precedes `loaded` in the serial).
#   JPEG  -- M136b (#2768): the bounded baseline decoder (webrender/jpeg.go).
#            The fixture is a stdlib-encoded baseline 4:2:0 file; the SOF0
#            sniff sizes the window before the decode.
#   JPROG -- the named refusal: the same fixture with its SOF0 marker byte
#            flipped to SOF2 (progressive) in setup. The sniff still sizes
#            the window off SOF2, then the decoder refuses by name
#            (`gview: unsupported JPEG`) and the viewer exits cleanly.
#   NOPE  -- the other error surface, and the default window when there is no
#            header at all: `gview: open err`, 320x240, still exits cleanly on
#            `q`.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goview.sh   ->  .build/go/GOVIEW.ELF
#
# exec-order: assert-proven -- every run ends on `user-exec exited status=43`,
# which only the viewer's own exit produces, and the key burst is gated on the
# app's `gview: ready`.

vgate_name live-image-viewer "M36 IMG5 + M71h: GOVIEW.ELF paints QOI, pans/zooms, and surfaces the PNG gap on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PYEOF'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOVIEW.ELF")
if not os.path.exists(src):
    sys.exit("GOVIEW.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goview.sh")
shutil.copy(src, os.path.join(share, "GOVIEW.ELF"))
shutil.copy("tests/fixtures/qoi/viewer_160x120.qoi", os.path.join(share, "TEST.QOI"))
shutil.copy("tests/fixtures/png/viewer_160x120.png", os.path.join(share, "TEST.PNG"))
shutil.copy("user/go/webrender/testdata/jpeg/viewer_160x120.jpg",
            os.path.join(share, "TEST.JPG"))
# JPROG: the same file with the SOF0 marker byte flipped to SOF2 — a
# progressive refusal built from our own fixture, no external JPEG needed.
jpg = open("user/go/webrender/testdata/jpeg/viewer_160x120.jpg", "rb").read()
pos = jpg.find(b"\xff\xc0")
assert pos > 0, "baseline fixture lost its SOF0 marker"
prog = bytearray(jpg)
prog[pos + 1] = 0xc2
open(os.path.join(share, "JPROG.JPG"), "wb").write(bytes(prog))
print("staged GOVIEW.ELF + TEST.QOI/PNG/JPG (%d bytes) + JPROG.JPG" % len(jpg))
PYEOF

vgate_file script-qoi.txt <<'EOF'
exec GOVIEW.ELF /host/TEST.QOI
EOF

vgate_file script-png.txt <<'EOF'
exec GOVIEW.ELF /host/TEST.PNG
EOF

vgate_file script-jpeg.txt <<'EOF'
exec GOVIEW.ELF /host/TEST.JPG
EOF

vgate_file script-jprog.txt <<'EOF'
exec GOVIEW.ELF /host/JPROG.JPG
EOF

vgate_file script-missing.txt <<'EOF'
exec GOVIEW.ELF /host/NOPE.QOI
EOF

# `syscalls` proves the title really crossed the slot-61 boundary (see the
# `sys_win_set_title calls=` assert below): the Go wrapper for that slot lands
# in this card, because until GOVIEW no Go app had to title a window itself.
vgate_file script-syscalls.txt <<'EOF'
syscalls
EOF

# --- Boot QOI: the happy path, with the key burst. -------------------------
vgate_run QOI -- \
    --display --screen '$RUN_DIR/gpu-screen-qoi' \
    --via-virtio \
    --script '$RUN_DIR/script-qoi.txt' --script-after "virelai> " \
    --input-chords "=,=,=,=,=,=,up,left,right,down,down,down,down,0,-,q" --input-chords-after "gview: ready" \
    --script2 '$RUN_DIR/script-syscalls.txt' --script2-after "gview: ready" \
    --script-expect "user-exec exited status=43" --timeout 200

vgate_assert QOI serial-contains "VirelaiOS kernel has seized control."
vgate_assert QOI serial-contains "exec: loaded GOVIEW.ELF"
vgate_assert QOI serial-contains "gview: loaded TEST.QOI 160x120 QOI bytes=340"
vgate_assert QOI serial-contains "gview: title set"
vgate_assert QOI serial-contains "gview: ready"
vgate_assert QOI serial-contains "gview: zoom z=150%"
vgate_assert QOI serial-contains "gview: zoom z=800%"
vgate_assert QOI serial-contains "gview: zoom z=100%"
vgate_assert QOI serial-contains "gview: zoom z=66%"
vgate_assert QOI serial-contains "gview: quit"
vgate_assert QOI serial-contains "user-exec exited status=43"
vgate_assert QOI serial-absent "[EXC] parking:"
vgate_assert QOI python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
# The window is sized from the file's own header before it opens: 2x the
# 160x120 image plus the viewer's padding. This is the number Zig VIEW.BIN
# printed, which is what makes the retarget a continuity proof.
assert re.search(r"gview: open id=[0-9]+ 328x264", ser), "open dimension check failed"
assert re.search(r"sys_win_set_title calls=[1-9][0-9]*", ser), "title syscall check failed"
pans = re.findall(r"gview: pan ox=([0-9]+) oy=([0-9]+)", ser)
assert pans, "no pan markers: the arrow keys never reached the app"
assert any(int(oy) > 0 for _, oy in pans), \
    "pan stayed at oy=0 -- the arrows moved nothing: %r" % (pans,)
PY

# --- Boot PNG: the honest gap. --------------------------------------------
vgate_run PNG -- \
    --display --screen '$RUN_DIR/gpu-screen-png' \
    --via-virtio \
    --script '$RUN_DIR/script-png.txt' --script-after "virelai> " \
    --input-chords "q" --input-chords-after "gview: ready" \
    --script-expect "user-exec exited status=43" --timeout 150

vgate_assert PNG serial-contains "exec: loaded GOVIEW.ELF"
vgate_assert PNG serial-contains "gview: loaded TEST.PNG 160x120 PNG bytes=420"
vgate_assert PNG serial-absent "gview: unsupported"
vgate_assert PNG serial-contains "gview: ready"
vgate_assert PNG serial-contains "gview: quit"
vgate_assert PNG serial-contains "user-exec exited status=43"
vgate_assert PNG serial-absent "[EXC] parking:"
vgate_assert PNG python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
# Still sized from the PNG IHDR: the header sniff does not need a decoder.
assert re.search(r"gview: open id=[0-9]+ 328x264", ser), \
    "the PNG boot did not size its window from the IHDR header"
PY

# --- Boot JPEG: baseline decodes in guest, window sized off the SOF0. -----
vgate_run JPEG -- \
    --display --screen '$RUN_DIR/gpu-screen-jpeg' \
    --via-virtio \
    --script '$RUN_DIR/script-jpeg.txt' --script-after "virelai> " \
    --input-chords "q" --input-chords-after "gview: ready" \
    --script-expect "user-exec exited status=43" --timeout 150

vgate_assert JPEG serial-contains "exec: loaded GOVIEW.ELF"
vgate_assert JPEG serial-contains "gview: loaded TEST.JPG 160x120 JPEG bytes=1987"
vgate_assert JPEG serial-absent "gview: unsupported"
vgate_assert JPEG serial-contains "gview: ready"
vgate_assert JPEG serial-contains "gview: quit"
vgate_assert JPEG serial-contains "user-exec exited status=43"
vgate_assert JPEG serial-absent "[EXC] parking:"
vgate_assert JPEG python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
# Sized from the JPEG SOF0: the marker-chain sniff does not need a decoder.
assert re.search(r"gview: open id=[0-9]+ 328x264", ser), \
    "the JPEG boot did not size its window from the SOF0 header"
PY

# --- Boot JPROG: the named refusal — progressive refuses, cleanly. --------
vgate_run JPROG -- \
    --display --screen '$RUN_DIR/gpu-screen-jprog' \
    --via-virtio \
    --script '$RUN_DIR/script-jprog.txt' --script-after "virelai> " \
    --input-chords "q" --input-chords-after "gview: ready" \
    --script-expect "user-exec exited status=43" --timeout 150

vgate_assert JPROG serial-contains "exec: loaded GOVIEW.ELF"
vgate_assert JPROG serial-contains "gview: unsupported JPEG"
vgate_assert JPROG serial-absent "gview: loaded "
vgate_assert JPROG serial-contains "gview: ready"
vgate_assert JPROG serial-contains "gview: quit"
vgate_assert JPROG serial-contains "user-exec exited status=43"
vgate_assert JPROG serial-absent "[EXC] parking:"
vgate_assert JPROG python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
# The sniff sizes the window off SOF2 even though the decode will refuse.
assert re.search(r"gview: open id=[0-9]+ 328x264", ser), \
    "the progressive boot did not size its window from the SOF header"
PY

# --- Boot NOPE: the other error surface, and the default window. ----------
vgate_run NOPE -- \
    --display --screen '$RUN_DIR/gpu-screen-nope' \
    --via-virtio \
    --script '$RUN_DIR/script-missing.txt' --script-after "virelai> " \
    --input-chords "q" --input-chords-after "gview: ready" \
    --script-expect "user-exec exited status=43" --timeout 150

vgate_assert NOPE serial-contains "exec: loaded GOVIEW.ELF"
vgate_assert NOPE serial-contains "gview: open err"
vgate_assert NOPE serial-contains "gview: ready"
vgate_assert NOPE serial-contains "user-exec exited status=43"
vgate_assert NOPE serial-absent "[EXC] parking:"
vgate_assert NOPE python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
# No header to read: the default window, and no loaded marker at all.
assert re.search(r"gview: open id=[0-9]+ 320x240", ser), \
    "a file with no readable header must open the default window"
assert "gview: loaded " not in ser, "an unreadable file must not report a load"
PY
