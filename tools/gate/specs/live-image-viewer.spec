# live-image-viewer.spec -- M136d (#2770): five formats in one viewer, K=3.
# Third retarget of the M36 IMG5 gate (M71h #1567 moved it onto GOVIEW.ELF,
# M93e/M136b/M136c added the PNG/JPEG/GIF legs): vgate_repeat is spec-global,
# and this card's iteration IS one boot, so the seven per-format boots close
# into a single journey boot replayed three times.
#
# Each boot first raises WND.BIN (`wnd start`) — under a registered WM the
# composite paces on the scheduler tick, so the scanout is fresh while the
# shell is busy (the shim composite only runs in the shell's idle loop —
# snaps taken on it captured the bare desktop, observed). Then PNG, JPEG,
# GIF, SVG and QOI fixtures open in GOVIEW in sequence — the five viewers
# coexist (the window cap is 8), each new exec's window landing on top of
# the last. Every `gview: loaded` receipt is followed by an `fg` dwell
# (paint + composite settle), then an `echo snap-<fmt>` marker that fires
# that leg's kind-4 BGRX scanout snap, then a SECOND `fg` dwell that
# keeps the next exec ~5s away while the 3.5 MiB stream runs — the
# marker-settle idiom from go-calc run 05. Firing on the dwell's own END
# line raced the next `open:`: the request is queued host-side while the
# guest keeps running, and the observed snap showed the NEW window's
# `dui3` title over its still-empty client — an unfaded frame occluding
# the painted leg beneath. The padding dwell removes the race entirely.
# JPROG is the JPEG fixture with its SOF0 byte flipped to SOF2 in setup;
# its named refusal `gview: unsupported JPEG` is where the one `q` chord
# lands, ending the boot on the viewer's own exit 43. The SVG comes by
# path (GOFILES mime dispatch is M132b's row, covered by M143b); GOVIEW
# sniffs no SVG header, so it opens the 320x240 default window and its
# receipt honestly tags `???` while the decoded 64x64 still proves the
# raster. Issue #2975 made the GIF leg animated: TEST.GIF is the
# three-frame anim3_160x120.gif, and `--input-string '..'` (the run's
# second input channel — --input-chords is spent on the `q`) presses the
# frame stepper twice so the serial carries `gview: frame 1/3`, `2/3`,
# `3/3` with three distinct pixel sums.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goview.sh   ->  .build/go/GOVIEW.ELF
#
# exec-order: assert-proven -- the run ends on `user-exec exited
# status=43`, which only the last viewer's `q`-driven quit produces; the
# `fg` dwells pace the sequence and every assert reads output only the
# guest produces.

vgate_name live-image-viewer "M136d (#2770): one boot decodes PNG+JPEG+GIF+SVG+QOI in GOVIEW in sequence — size markers, scanout pixel probes, JPROG named refusal — K=3"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

vgate_setup_python <<'PYEOF'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOVIEW.ELF")
if not os.path.exists(src):
    sys.exit("GOVIEW.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goview.sh")
shutil.copy(src, os.path.join(share, "GOVIEW.ELF"))
shutil.copy("tests/fixtures/png/viewer_160x120.png", os.path.join(share, "TEST.PNG"))
shutil.copy("user/go/webrender/testdata/jpeg/viewer_160x120.jpg",
            os.path.join(share, "TEST.JPG"))
shutil.copy("user/go/webrender/testdata/gif/anim3_160x120.gif",
            os.path.join(share, "TEST.GIF"))
shutil.copy("tests/fixtures/svg/acceptance/rect.svg", os.path.join(share, "TEST.SVG"))
shutil.copy("tests/fixtures/qoi/viewer_160x120.qoi", os.path.join(share, "TEST.QOI"))
# JPROG: the same JPEG with the SOF0 marker byte flipped to SOF2 — a
# progressive refusal built from our own fixture, no external JPEG needed.
jpg = open("user/go/webrender/testdata/jpeg/viewer_160x120.jpg", "rb").read()
pos = jpg.find(b"\xff\xc0")
assert pos > 0, "baseline fixture lost its SOF0 marker"
prog = bytearray(jpg)
prog[pos + 1] = 0xc2
open(os.path.join(share, "JPROG.JPG"), "wb").write(bytes(prog))
print("staged GOVIEW.ELF + TEST.PNG/JPG/GIF/SVG/QOI + JPROG.JPG (GIF leg is the three-frame anim3)")
PYEOF

# The sequence per leg: `exec ... &`, a bounded ~5-tick `fg` dwell (the
# viewers only exit on input, so it always runs its full course — the
# open+decode+present+composite all land inside it), then a unique
# `echo snap-<fmt>` marker, then a SECOND `fg` dwell that holds the next
# exec ~5s away. The kind-4 request fires on the marker and streams the
# scanout inside that second dwell, so the leg's window is still topmost
# and fully painted — the marker-settle idiom from go-calc run 05, and
# the fix for the observed race where a snap taken at the dwell's END
# caught the NEXT window's unfaded frame occluding the leg's own (the
# PNG snap showed a fresh `dui3` title over a black client). Legs 1-4
# take job slots 1-4 (all stay alive); QOI's dwells ride job 1. JPROG
# rides no `&` — the `q` chord quits it.
vgate_file script-wm.txt <<'EOF'
wnd start
EOF

vgate_file script.txt <<'EOF'
exec GOVIEW.ELF /host/TEST.PNG &
fg 1
echo snap-png
fg 1
exec GOVIEW.ELF /host/TEST.JPG &
fg 2
echo snap-jpg
fg 2
exec GOVIEW.ELF /host/TEST.GIF &
fg 3
echo snap-gif
fg 3
exec GOVIEW.ELF /host/TEST.SVG &
fg 4
echo snap-svg
fg 4
exec GOVIEW.ELF /host/TEST.QOI
fg 1
echo snap-qoi
fg 1
exec GOVIEW.ELF /host/JPROG.JPG
EOF

# --- The five-format journey, one boot -----------------------------------
# Five --snapshot-after triggers, one unique echo marker per leg; each
# fires during that leg's padding dwell (see above).
vgate_run 01 -- \
    --display --screen '$RUN_DIR/gpu-screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap' \
    --snapshot-after 'snap-png' \
    --snapshot-after 'snap-jpg' \
    --snapshot-after 'snap-gif' \
    --snapshot-after 'snap-svg' \
    --snapshot-after 'snap-qoi' \
    --script '$RUN_DIR/script-wm.txt' --script-after "virelai> " \
    --script2 '$RUN_DIR/script.txt' --script2-after "wnd: registered" \
    --input-string '..' --input-string-after "gview: loaded TEST.GIF" \
    --input-chords "q" --input-chords-after "gview: unsupported JPEG" \
    --script-expect "user-exec exited status=43" --timeout 240

vgate_assert 01 serial-contains "VirelaiOS kernel has seized control."
vgate_assert 01 serial-contains "wnd: registered"
vgate_assert 01 serial-contains "gview: not-tab-aware (shim or WND desktop)"
vgate_assert 01 serial-count "exec: loaded GOVIEW.ELF" 6
# The size markers — filename, decoded geometry, format tag, byte count.
vgate_assert 01 serial-contains "gview: loaded TEST.PNG 160x120 PNG bytes=420"
vgate_assert 01 serial-contains "gview: loaded TEST.JPG 160x120 JPEG bytes=1987"
vgate_assert 01 serial-contains "gview: loaded TEST.GIF 160x120 GIF bytes=23271 frames=3"
vgate_assert 01 serial-contains "gview: loaded TEST.SVG 64x64 ??? bytes=287"
vgate_assert 01 serial-contains "gview: loaded TEST.QOI 160x120 QOI bytes=340"
# Every snap marker echoed this boot — a snap file can then never be a
# stale sibling from an earlier iteration.
vgate_assert 01 serial-contains "snap-png"
vgate_assert 01 serial-contains "snap-jpg"
vgate_assert 01 serial-contains "snap-gif"
vgate_assert 01 serial-contains "snap-svg"
vgate_assert 01 serial-contains "snap-qoi"
# The frame stepper (issue #2975): `--input-string '..'` types two `.` key
# presses into the focused GIF viewer right after its loaded receipt — the
# second input channel, since --input-chords is spent on JPROG's `q`. Frame
# 1's receipt prints at load; the two presses walk it to 3/3. The GIF leg's
# pixel probe below still passes whichever frame the snap catches: all
# three are the same dense pattern family.
vgate_assert 01 serial-contains "gview: frame 1/3 delay=100 sum="
vgate_assert 01 serial-contains "gview: frame 2/3 delay=100 sum="
vgate_assert 01 serial-contains "gview: frame 3/3 delay=100 sum="
# The named refusal, then the viewer's own quit.
vgate_assert 01 serial-contains "gview: unsupported JPEG"
vgate_assert 01 serial-contains "gview: quit"
vgate_assert 01 serial-contains "user-exec exited status=43"
vgate_assert 01 serial-absent "[EXC] parking:"
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# The sequence itself: the five loaded receipts in the card's order and
# nothing else loading — JPROG never reports one.
order = ["gview: loaded TEST.%s" % n for n in ("PNG", "JPG", "GIF", "SVG", "QOI")]
pos = [ser.find(m) for m in order]
if -1 in pos or pos != sorted(pos):
    sys.exit("loaded receipts missing or out of order: %r" % (pos,))
if "gview: loaded JPROG" in ser or ser.count("gview: loaded ") != 5:
    sys.exit("loaded-receipt count wrong (JPROG must not load)")
# Exactly one refusal, from the hostile leg, and one honest quit.
if ser.count("gview: unsupported ") != 1:
    sys.exit("unsupported refusal count != 1")
if ser.count("gview: quit") != 1 or ser.count("user-exec exited status=43") != 1:
    sys.exit("expected exactly one quit -> status=43 (the JPROG viewer)")
# Window sizing: the four sniffed rasters + JPROG open 328x264; the
# headerless SVG takes the 320x240 default.
if len(re.findall(r"gview: open id=\d+ 328x264", ser)) != 5:
    sys.exit("expected five 328x264 opens (PNG/JPG/GIF/QOI/JPROG)")
if len(re.findall(r"gview: open id=\d+ 320x240", ser)) != 1:
    sys.exit("expected one 320x240 default open (SVG)")
# The stepper's three receipts must carry three DISTINCT pixel sums —
# anim3's frames differ per frame, so an equal pair means a step repainted
# stale pixels.
sums = re.findall(r"gview: frame (\d+)/3 delay=100 sum=([0-9a-f]+)", ser)
if [i for i, _ in sums] != ["1", "2", "3"] or len({s for _, s in sums}) != 3:
    sys.exit("frame receipts wrong: %r" % (sums,))
print("sequence, refusals, exits, window sizes and frame sums all pinned")
PY

# --- the probes' anchor --------------------------------------------------
# WND places a window where the desktop wants it (rect varies run to
# run), so the probes never guess a position: the kernel logs
# `open: id=N owner=P rect=X,Y WxH` for every win_open and GOVIEW logs
# `gview: open id=N` immediately before each `gview: loaded` receipt, so
# each leg's on-scanout rect is recovered from the serial (it sits next
# to the snapshot in RUN_DIR as vm-serial-*.log). Inside the window the
# layout is the app's own contract: the canvas covers the whole rect,
# the kernel paints its 16px title band and 2px border over it, and the
# image centers in the viewport (title band 16 + status 12) at 100% —
# the checks below verify the fixture's structure at those computed
# pixels. The leg's window is focused-and-topmost at snap time (opaque
# client), but the probes still read hues rather than absolute colors —
# a rest-alpha change must not break the gate. The checkerboard behind
# the image is the viewer's own transparent-pixel backdrop.

# --- pixel probe 1: PNG — warm left half, gray right half ----------------
vgate_assert 01 snapshot 'snap-0.raw' <<'PY'
import glob, os, re, sys
raw = open(sys.argv[1], "rb").read()
W, H = 1280, 720
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %dx%d BGRX" % (len(raw), W, H))
def px(x, y):
    k = (y * W + x) * 4
    return (raw[k + 2], raw[k + 1], raw[k])
rd = os.path.dirname(os.path.abspath(sys.argv[1]))
sers = glob.glob(os.path.join(rd, "vm-serial-*.log"))
if not sers:
    sys.exit("no vm-serial-*.log beside the snapshot")
# vgate_repeat writes one serial per iteration (vm-serial-01-0N.log) —
# the newest is THIS boot's, the anchor must not read a stale sibling.
ser = open(max(sers, key=os.path.getmtime), errors="replace").read()
pos = ser.find("gview: loaded TEST.PNG")
if pos < 0:
    sys.exit("PNG loaded receipt missing from serial")
ids = re.findall(r"gview: open id=(\d+)", ser[:pos])
m = re.search(r"open: id=%s owner=\d+ rect=(\d+),(\d+) (\d+)x(\d+)" % ids[-1], ser)
if not m:
    sys.exit("no kernel open rect for viewer window id=%s" % ids[-1])
rx, ry, rw, rh = map(int, m.groups())
im = re.search(r"gview: loaded TEST\.PNG (\d+)x(\d+)", ser)
iw, ih = int(im.group(1)), int(im.group(2))
ix = rx + max(0, (rw - iw) // 2)
iy = ry + 16 + max(0, (rh - 28 - ih) // 2)
if ix < 0 or iy < 0 or ix + iw > W or iy + ih > H:
    sys.exit("anchored image rect (%d,%d %dx%d) escapes the scanout" % (ix, iy, iw, ih))
def warm(c):
    r, g, b = c
    return r > 140 and r > g + 40 and g > b + 20
def gray(c):
    r, g, b = c
    return 60 < r < 190 and abs(r - g) < 20 and abs(g - b) < 20
def frac(x0, x1, y0, y1, f):
    n = ok = 0
    for y in range(y0, y1, 6):
        for x in range(x0, x1, 6):
            n += 1
            ok += f(px(x, y))
    return ok / max(n, 1)
mid = ix + iw // 2
wf = frac(ix + 6, mid - 4, iy + 8, iy + ih - 8, warm)
gf = frac(mid + 4, ix + iw - 6, iy + 8, iy + ih - 8, gray)
if wf < 0.6 or gf < 0.6:
    sys.exit("PNG halves wrong: warm=%.2f gray=%.2f at img (%d,%d %dx%d)" % (wf, gf, ix, iy, iw, ih))
print("PNG-PIXELS-OK img=(%d,%d) %dx%d warm=%.2f gray=%.2f" % (ix, iy, iw, ih, wf, gf))
PY

# --- pixel probe 2: JPEG — red left half, green/blue right half ----------
# (the fixture's center also carries a magenta/cyan checker; the quadrant
# reads are the load-bearing half — JPEG is lossy, so the hue margins are
# wide and the quorum is a half, not exact colors).
vgate_assert 01 snapshot 'snap-1.raw' <<'PY'
import glob, os, re, sys
raw = open(sys.argv[1], "rb").read()
W, H = 1280, 720
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %dx%d BGRX" % (len(raw), W, H))
def px(x, y):
    k = (y * W + x) * 4
    return (raw[k + 2], raw[k + 1], raw[k])
rd = os.path.dirname(os.path.abspath(sys.argv[1]))
sers = glob.glob(os.path.join(rd, "vm-serial-*.log"))
if not sers:
    sys.exit("no vm-serial-*.log beside the snapshot")
# vgate_repeat writes one serial per iteration (vm-serial-01-0N.log) —
# the newest is THIS boot's, the anchor must not read a stale sibling.
ser = open(max(sers, key=os.path.getmtime), errors="replace").read()
pos = ser.find("gview: loaded TEST.JPG")
if pos < 0:
    sys.exit("JPG loaded receipt missing from serial")
ids = re.findall(r"gview: open id=(\d+)", ser[:pos])
m = re.search(r"open: id=%s owner=\d+ rect=(\d+),(\d+) (\d+)x(\d+)" % ids[-1], ser)
if not m:
    sys.exit("no kernel open rect for viewer window id=%s" % ids[-1])
rx, ry, rw, rh = map(int, m.groups())
im = re.search(r"gview: loaded TEST\.JPG (\d+)x(\d+)", ser)
iw, ih = int(im.group(1)), int(im.group(2))
ix = rx + max(0, (rw - iw) // 2)
iy = ry + 16 + max(0, (rh - 28 - ih) // 2)
if ix < 0 or iy < 0 or ix + iw > W or iy + ih > H:
    sys.exit("anchored image rect (%d,%d %dx%d) escapes the scanout" % (ix, iy, iw, ih))
def red(c):
    r, g, b = c
    return r > 110 and r > g + 60 and r > b + 60
def green(c):
    r, g, b = c
    return g > 90 and g > r + 50 and g > b + 30
def blue(c):
    r, g, b = c
    return b > 110 and b > r + 60 and b > g + 40
def frac(x0, x1, y0, y1, f):
    n = ok = 0
    for y in range(y0, y1, 6):
        for x in range(x0, x1, 6):
            n += 1
            ok += f(px(x, y))
    return ok / max(n, 1)
mx = ix + iw // 2
my = iy + ih // 2
rf = frac(ix + 6, mx - 4, iy + 8, iy + ih - 8, red)
gf = frac(mx + 4, ix + iw - 6, iy + 8, my - 4, green)
bf = frac(mx + 4, ix + iw - 6, my + 4, iy + ih - 8, blue)
if rf < 0.5 or gf < 0.5 or bf < 0.5:
    sys.exit("JPEG zones wrong: red=%.2f green=%.2f blue=%.2f at img (%d,%d %dx%d)" % (rf, gf, bf, ix, iy, iw, ih))
print("JPEG-PIXELS-OK img=(%d,%d) %dx%d red=%.2f green=%.2f blue=%.2f" % (ix, iy, iw, ih, rf, gf, bf))
PY

# --- pixel probe 3: GIF — a dense many-hue palette pattern ---------------
vgate_assert 01 snapshot 'snap-2.raw' <<'PY'
import glob, os, re, sys
raw = open(sys.argv[1], "rb").read()
W, H = 1280, 720
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %dx%d BGRX" % (len(raw), W, H))
def px(x, y):
    k = (y * W + x) * 4
    return (raw[k + 2], raw[k + 1], raw[k])
rd = os.path.dirname(os.path.abspath(sys.argv[1]))
sers = glob.glob(os.path.join(rd, "vm-serial-*.log"))
if not sers:
    sys.exit("no vm-serial-*.log beside the snapshot")
# vgate_repeat writes one serial per iteration (vm-serial-01-0N.log) —
# the newest is THIS boot's, the anchor must not read a stale sibling.
ser = open(max(sers, key=os.path.getmtime), errors="replace").read()
pos = ser.find("gview: loaded TEST.GIF")
if pos < 0:
    sys.exit("GIF loaded receipt missing from serial")
ids = re.findall(r"gview: open id=(\d+)", ser[:pos])
m = re.search(r"open: id=%s owner=\d+ rect=(\d+),(\d+) (\d+)x(\d+)" % ids[-1], ser)
if not m:
    sys.exit("no kernel open rect for viewer window id=%s" % ids[-1])
rx, ry, rw, rh = map(int, m.groups())
im = re.search(r"gview: loaded TEST\.GIF (\d+)x(\d+)", ser)
iw, ih = int(im.group(1)), int(im.group(2))
ix = rx + max(0, (rw - iw) // 2)
iy = ry + 16 + max(0, (rh - 28 - ih) // 2)
if ix < 0 or iy < 0 or ix + iw > W or iy + ih > H:
    sys.exit("anchored image rect (%d,%d %dx%d) escapes the scanout" % (ix, iy, iw, ih))
# The fixture is a 16-entry palette pattern — a rendered decode is dense
# AND varied; a black or single-hue frame is not.
colors = set()
for y in range(iy + 4, iy + ih - 4, 4):
    for x in range(ix + 4, ix + iw - 4, 4):
        colors.add(px(x, y))
def colorful(c):
    return max(c) - min(c) > 40
ncolor = sum(1 for c in colors if colorful(c))
if len(colors) < 10 or ncolor < 8:
    sys.exit("GIF pattern too flat: %d colors, %d colorful at img (%d,%d %dx%d)" % (len(colors), ncolor, ix, iy, iw, ih))
# Adjacent-pixel churn: the pattern index changes every ~3px, so most
# neighbour samples must differ — a gradient would fail this.
same = diff = 0
for y in range(iy + 8, iy + ih - 8, 8):
    for x in range(ix + 8, ix + iw - 12, 8):
        if px(x, y) == px(x + 4, y):
            same += 1
        else:
            diff += 1
if diff <= same:
    sys.exit("GIF pattern has no churn: %d diff vs %d same" % (diff, same))
print("GIF-PIXELS-OK img=(%d,%d) %dx%d colors=%d colorful=%d churn=%d/%d" % (ix, iy, iw, ih, len(colors), ncolor, diff, diff + same))
PY

# --- pixel probe 4: SVG — rect.svg's four fills, inside the 64x64 --------
vgate_assert 01 snapshot 'snap-3.raw' <<'PY'
import glob, os, re, sys
raw = open(sys.argv[1], "rb").read()
W, H = 1280, 720
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %dx%d BGRX" % (len(raw), W, H))
def px(x, y):
    k = (y * W + x) * 4
    return (raw[k + 2], raw[k + 1], raw[k])
rd = os.path.dirname(os.path.abspath(sys.argv[1]))
sers = glob.glob(os.path.join(rd, "vm-serial-*.log"))
if not sers:
    sys.exit("no vm-serial-*.log beside the snapshot")
# vgate_repeat writes one serial per iteration (vm-serial-01-0N.log) —
# the newest is THIS boot's, the anchor must not read a stale sibling.
ser = open(max(sers, key=os.path.getmtime), errors="replace").read()
pos = ser.find("gview: loaded TEST.SVG")
if pos < 0:
    sys.exit("SVG loaded receipt missing from serial")
ids = re.findall(r"gview: open id=(\d+)", ser[:pos])
m = re.search(r"open: id=%s owner=\d+ rect=(\d+),(\d+) (\d+)x(\d+)" % ids[-1], ser)
if not m:
    sys.exit("no kernel open rect for viewer window id=%s" % ids[-1])
rx, ry, rw, rh = map(int, m.groups())
im = re.search(r"gview: loaded TEST\.SVG (\d+)x(\d+)", ser)
iw, ih = int(im.group(1)), int(im.group(2))
ix = rx + max(0, (rw - iw) // 2)
iy = ry + 16 + max(0, (rh - 28 - ih) // 2)
if ix < 0 or iy < 0 or ix + iw > W or iy + ih > H:
    sys.exit("anchored image rect (%d,%d %dx%d) escapes the scanout" % (ix, iy, iw, ih))
# rect.svg's four fills, at image-relative interior points (the rasterizer
# may anti-alias edges, so each probe is a 5x5 majority vote at the rect's
# centre): steel #2468ac (2,2,16x16), tan #c84 (22,2,18x18), green
# (44,2,18x18), blue (8,30,48x28).
def steel(c):
    r, g, b = c
    return r < 110 and b > 120 and b > g + 30 and g > r + 30
def tan(c):
    r, g, b = c
    return r > 140 and g > 80 and g < r and b < g - 30
def green(c):
    r, g, b = c
    return g > 80 and g > r * 2 and g > b * 2
def blue(c):
    r, g, b = c
    return b > 140 and b > r * 3 and b > g * 3
def patch(cx, cy, f):
    n = ok = 0
    for y in range(cy - 2, cy + 3):
        for x in range(cx - 2, cx + 3):
            n += 1
            ok += f(px(ix + x, iy + y))
    return ok / max(n, 1)
s = patch(10, 10, steel)
t = patch(31, 11, tan)
g = patch(53, 11, green)
b = patch(32, 44, blue)
if s < 0.6 or t < 0.6 or g < 0.6 or b < 0.6:
    sys.exit("SVG fills wrong: steel=%.2f tan=%.2f green=%.2f blue=%.2f at img (%d,%d)" % (s, t, g, b, ix, iy))
print("SVG-PIXELS-OK img=(%d,%d) %dx%d steel=%.2f tan=%.2f green=%.2f blue=%.2f" % (ix, iy, iw, ih, s, t, g, b))
PY

# --- pixel probe 5: QOI — warm top half, steel bottom half ----------------
vgate_assert 01 snapshot 'snap-4.raw' <<'PY'
import glob, os, re, sys
raw = open(sys.argv[1], "rb").read()
W, H = 1280, 720
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %dx%d BGRX" % (len(raw), W, H))
def px(x, y):
    k = (y * W + x) * 4
    return (raw[k + 2], raw[k + 1], raw[k])
rd = os.path.dirname(os.path.abspath(sys.argv[1]))
sers = glob.glob(os.path.join(rd, "vm-serial-*.log"))
if not sers:
    sys.exit("no vm-serial-*.log beside the snapshot")
# vgate_repeat writes one serial per iteration (vm-serial-01-0N.log) —
# the newest is THIS boot's, the anchor must not read a stale sibling.
ser = open(max(sers, key=os.path.getmtime), errors="replace").read()
pos = ser.find("gview: loaded TEST.QOI")
if pos < 0:
    sys.exit("QOI loaded receipt missing from serial")
ids = re.findall(r"gview: open id=(\d+)", ser[:pos])
m = re.search(r"open: id=%s owner=\d+ rect=(\d+),(\d+) (\d+)x(\d+)" % ids[-1], ser)
if not m:
    sys.exit("no kernel open rect for viewer window id=%s" % ids[-1])
rx, ry, rw, rh = map(int, m.groups())
im = re.search(r"gview: loaded TEST\.QOI (\d+)x(\d+)", ser)
iw, ih = int(im.group(1)), int(im.group(2))
ix = rx + max(0, (rw - iw) // 2)
iy = ry + 16 + max(0, (rh - 28 - ih) // 2)
if ix < 0 or iy < 0 or ix + iw > W or iy + ih > H:
    sys.exit("anchored image rect (%d,%d %dx%d) escapes the scanout" % (ix, iy, iw, ih))
def warm(c):
    r, g, b = c
    return r > 140 and r > g + 40 and g > b + 20
def steel(c):
    r, g, b = c
    return b > 90 and b > r + 60 and g > r + 20
def frac(x0, x1, y0, y1, f):
    n = ok = 0
    for y in range(y0, y1, 6):
        for x in range(x0, x1, 6):
            n += 1
            ok += f(px(x, y))
    return ok / max(n, 1)
my = iy + ih // 2
wf = frac(ix + 6, ix + iw - 6, iy + 8, my - 4, warm)
sf = frac(ix + 6, ix + iw - 6, my + 4, iy + ih - 8, steel)
if wf < 0.6 or sf < 0.6:
    sys.exit("QOI halves wrong: warm=%.2f steel=%.2f at img (%d,%d %dx%d)" % (wf, sf, ix, iy, iw, ih))
print("QOI-PIXELS-OK img=(%d,%d) %dx%d warm=%.2f steel=%.2f" % (ix, iy, iw, ih, wf, sf))
PY
