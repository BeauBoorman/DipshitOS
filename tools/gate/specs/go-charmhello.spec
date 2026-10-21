# go-charmhello.spec -- M72c: an actual Bubble Tea v2 Model consumes HID keys
# from a bound /dev/tty and writes its ANSI View into the kernel-painted grid.
# The capture is the default GOTABWM scanout (not reconstructed ANSI): the
# post-HID frame must be 2560x1440 and carry both the Tea title and PAUSED
# colour. Charm modules stay in the host module cache; no vendor tree exists.
#
# exec-order: assert-proven -- input waits for the app's ready marker, capture
# waits for its post-key repaint marker, and the close waits for `dui`.

vgate_name go-charmhello "M72c: Bubble Tea v2 Model on a bound tty, real HID input and default-seat scanout pixels"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec CHARMHELLO.ELF
EOF

vgate_file script2.txt <<'EOF'
dui
EOF

vgate_file script3.txt <<'EOF'
dui close 2
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
src = os.path.join(".build", "go", "CHARMHELLO.ELF")
if not os.path.exists(src):
    sys.exit("CHARMHELLO.ELF missing (build it first: bash tools/go/build-charmhello.sh)")
shutil.copy(src, os.path.join(share, "CHARMHELLO.ELF"))
print("staged CHARMHELLO.ELF into share (%d bytes)" % os.path.getsize(src))
psrc = os.path.join(".build", "go", "PULSE.ELF")
if not os.path.exists(psrc):
    sys.exit("PULSE.ELF missing (build it first: bash tools/go/build-pulse.sh)")
shutil.copy(psrc, os.path.join(share, "PULSE.ELF"))
print("staged PULSE.ELF into share (%d bytes)" % os.path.getsize(psrc))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/charmhello-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --input-chords 'space' \
    --input-chords-after 'charmhello: ready' \
    --screenshot-after 'charmhello: repainted' \
    --pointer-virtio '60,76,c' \
    --pointer-virtio-after 'charmhello: key space' \
    --input-string 'r' \
    --input-string-after 'charmhello: mouse b=32' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'charmhello: size 64x23' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'dui: windows=' \
    --script-expect 'charmhello: close' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded CHARMHELLO.ELF'
vgate_assert 01 serial-contains 'charmhello: open id='
vgate_assert 01 serial-contains 'charmhello: attached'
# M168a (#2957): the app runs a real Bubble Tea v2 Program — decoder,
# renderer, mouse, resize and quit are the framework's, not a hand loop.
vgate_assert 01 serial-contains 'charmhello: program'
vgate_assert 01 serial-contains 'charmhello: painted'
vgate_assert 01 serial-contains 'charmhello: ready'
# M73j (#1636): the INITIAL tea.WindowSizeMsg — the first frame paints at
# the declared rect's real cells (640x400 -> clamp(640/8)=80 cols,
# (400-16)/16=24 rows; M73l #1661 cell_h=16), so a TUI's first frame is
# measured, not a guess. M168a: it now arrives through the Program's own
# initial-size path (term.GetSize -> teatty), not a hand-fed Update.
vgate_assert 01 serial-contains 'charmhello: size 80x24'
vgate_assert 01 serial-contains 'charmhello: key space'
vgate_assert 01 serial-contains 'charmhello: repainted'

# M73i (#1635): the app enabled ?1000/?1006 on its screen, so a plain click
# over its client area is reported TWICE — press `b=0` then release `b=32`,
# SGR `x/y` 1-based cells — and is never consumed by kernel selection.
# Geometry is observed, not assumed: `dui[4]` prints rect=32,32,640,400 and
# the title is 16 px, so the client origin is (32, 48); the click pixel
# (60, 76) is the 8x16 cell at col 3, row 1 (0-based; M73l #1661 cell_h=16)
# -> x=4 y=2. Choreography
# is deterministic: the click fires after the space chord and the `dui`
# script only runs after the RELEASE marker, so the window is alive for the
# whole pair. `term sel` never appearing on this run is the
# selection-precedence half of the contract (Shift keeps local selection).
vgate_assert 01 serial-contains 'charmhello: mouse b=0 x=4 y=2'
vgate_assert 01 serial-contains 'charmhello: mouse b=32 x=4 y=2'
vgate_assert 01 serial-absent 'dui: term sel begin'
vgate_assert 01 serial-absent 'dui: term sel end'
# M73j (#1636): after the click, the runner types `r` -> the app calls
# sys_win_resize(512,384) (owner seam, works under the seat where the
# kernel's grip path is WM-gated) -> WIN_RESIZE(arg0=512,arg1=384) ->
# tabapp ActionResized -> tea.WindowSizeMsg{64,23} in CELLS
# (512/8, (384-16)/16 — M73l #1661 cell_h=16) -> repaint + this marker. The startup marker above
# proves the initial message; this one proves the live resize path, and
# script2 only runs off it, so `dui`'s rect line describes the RESIZED
# window (the rect assert stays prefix-only by design).
vgate_assert 01 serial-contains 'charmhello: size 64x23'
vgate_assert 01 serial-contains 'dui[4]: user user rect='
vgate_assert 01 serial-contains 'charmhello: close'
vgate_assert 01 serial-contains 'charmhello OK'
vgate_assert 01 serial-absent 'SESSION.TXT.FRAMES'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The screenshot marker is an app marker emitted after the bound-tty write
# and a scheduler yield. It is not a monitor `script-expect` echo. Decode the
# host scanout itself: title magenta proves Tea's View, while PAUSED yellow
# proves the injected space HID key reached tea.Model.Update before capture.
vgate_assert 01 snapshot 'charmhello-screen-after' <<'PY'
import struct, sys, zlib

d = open(sys.argv[1], "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG scanout"
pos = 8
idat = b""
w = h = ct = 0
while pos < len(d):
    n, typ = struct.unpack(">I4s", d[pos:pos + 8])
    chunk = d[pos + 8:pos + 8 + n]
    if typ == b"IHDR":
        w, h, depth, ct = struct.unpack(">IIBB", chunk[:10])
        assert depth == 8, "unexpected PNG depth"
    elif typ == b"IDAT":
        idat += chunk
    pos += 12 + n
assert (w, h) == (2560, 1440), "wanted 2560x1440 scanout, got %dx%d" % (w, h)
bpp = 4 if ct == 6 else 3
raw = zlib.decompress(idat)
stride = w * bpp
out = bytearray()
prev = bytearray(stride)
i = 0
for _ in range(h):
    filt = raw[i]
    i += 1
    row = bytearray(raw[i:i + stride])
    i += stride
    if filt == 1:
        for x in range(bpp, stride):
            row[x] = (row[x] + row[x - bpp]) & 0xff
    elif filt == 2:
        for x in range(stride):
            row[x] = (row[x] + prev[x]) & 0xff
    elif filt == 3:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            row[x] = (row[x] + ((left + prev[x]) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up = prev[x]
            up_left = prev[x - bpp] if x >= bpp else 0
            p = left + up - up_left
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
            row[x] = (row[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else up_left)) & 0xff
    out += row
    prev = row

magenta = yellow = 0
for y in range(h):
    for x in range(w):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k + 1], out[k + 2]
        if r > 160 and 60 < g < 190 and b > 160:
            magenta += 1
        if r > 200 and g > 200 and b < 120:
            yellow += 1
print("Bubble Tea scanout: magenta=%d paused-yellow=%d" % (magenta, yellow))
assert magenta >= 100, "Bubble Tea title colour absent from scanout"
assert yellow >= 40, "HID space did not produce PAUSED state in scanout"
PY

# M72 pulse (#1609): the same Bubble Tea harness, but the Model reads the
# real sys_procs seam (slot 7) on its 1 Hz timer and renders the Processes
# tab after a real HID '2' key. PULSE.ELF is staged by the setup block above.
vgate_file pulsescript.txt <<'EOF'
exec PULSE.ELF
EOF

vgate_file pulsescript2.txt <<'EOF'
dui
EOF

vgate_file pulsescript3.txt <<'EOF'
dui close 2
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/pulse-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/pulsescript.txt' \
    --input-chords '2' \
    --input-chords-after 'pulse: ready' \
    --screenshot-after 'pulse: key 2' \
    --script2 '$RUN_DIR/pulsescript2.txt' \
    --script2-after 'pulse: key 2' \
    --script3 '$RUN_DIR/pulsescript3.txt' \
    --script3-after 'dui: windows=' \
    --script-expect 'pulse: close' --timeout 240

vgate_assert 02 serial-contains 'exec: loaded PULSE.ELF'
vgate_assert 02 serial-contains 'pulse: open id='
vgate_assert 02 serial-contains 'pulse: attached'
vgate_assert 02 serial-contains 'pulse: painted'
vgate_assert 02 serial-contains 'pulse: ready'
vgate_assert 02 serial-contains 'pulse: procs '
vgate_assert 02 serial-contains 'pulse: key 2'
vgate_assert 02 serial-contains 'pulse: repainted'
vgate_assert 02 serial-contains 'pulse: close'
vgate_assert 02 serial-contains 'pulse OK'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# The screenshot barrier is the `pulse: key 2` marker itself: main.go emits
# it only after the key has been processed *and* the new model painted, so
# the frame must show the Processes tab: magenta title (Tea's View) and the
# cyan tab bar. Waiting on `pulse: repainted` would race the 1 Hz timer,
# which emits the same marker on every tick. The `pulse: procs` serial
# marker proves the rows came from the real slot-7 seam, not canned data.
vgate_assert 02 snapshot 'pulse-screen-after' <<'PY'
import struct, sys, zlib

d = open(sys.argv[1], "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG scanout"
pos = 8
idat = b""
w = h = ct = 0
while pos < len(d):
    n, typ = struct.unpack(">I4s", d[pos:pos + 8])
    chunk = d[pos + 8:pos + 8 + n]
    if typ == b"IHDR":
        w, h, depth, ct = struct.unpack(">IIBB", chunk[:10])
        assert depth == 8, "unexpected PNG depth"
    elif typ == b"IDAT":
        idat += chunk
    pos += 12 + n
assert (w, h) == (2560, 1440), "wanted 2560x1440 scanout, got %dx%d" % (w, h)
bpp = 4 if ct == 6 else 3
raw = zlib.decompress(idat)
stride = w * bpp
out = bytearray()
prev = bytearray(stride)
i = 0
for _ in range(h):
    filt = raw[i]
    i += 1
    row = bytearray(raw[i:i + stride])
    i += stride
    if filt == 1:
        for x in range(bpp, stride):
            row[x] = (row[x] + row[x - bpp]) & 0xff
    elif filt == 2:
        for x in range(stride):
            row[x] = (row[x] + prev[x]) & 0xff
    elif filt == 3:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            row[x] = (row[x] + ((left + prev[x]) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up = prev[x]
            up_left = prev[x - bpp] if x >= bpp else 0
            p = left + up - up_left
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
            row[x] = (row[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else up_left)) & 0xff
    out += row
    prev = row

magenta = cyan = 0
for y in range(h):
    for x in range(w):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k + 1], out[k + 2]
        if r > 160 and 60 < g < 190 and b > 160:
            magenta += 1
        if r < 120 and g > 150 and b > 180:
            cyan += 1
print("Pulse scanout: magenta=%d cyan=%d" % (magenta, cyan))
assert magenta >= 100, "Pulse title colour absent from scanout"
assert cyan >= 60, "Pulse tab bar absent from scanout"
PY
