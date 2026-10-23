# live-desktop-typing.spec — keys reach a Go GUI app launched by GOSH.
#
# M78c retires the old Zig launcher. The Go shell's headless `exec` path is the
# minimal existing launcher seam for this input gate: it starts NOTE.ELF via
# sys_exec, and the focused window receives real HID strings. The manifest
# launcher and hosted-client lifecycle remain covered by live-desktop.

vgate_name live-desktop-typing "keys reach a Go GUI app launched by GOSH on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
exec GOSH.ELF -c "exec NOTE.ELF"
EOF

vgate_file script3.txt <<'EOF'
input
dui
tasks
echo desktop-typing-sweep-done
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, script in (("GOSH.ELF", "build-gosh.sh"),
                      ("NOTE.ELF", "build-note.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash tools/go/%s"
                 % (name, src, script))
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)"
          % (name, os.path.getsize(os.path.join(share, name))))
PY

vgate_run A -- \
    --display --input --screen '$RUN_DIR/gpu-screen' \
    --script '$RUN_DIR/script.txt' \
    --input-chords 'a,b,c,d,e,ctrl-s,ctrl-f,b,return,escape' \
    --input-chords-after 'note: ready' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'note: saved ok n=5' \
    --screenshot-after 'note: saved ok n=5' \
    --script-expect 'desktop-typing-sweep-done' \
    --timeout 180

vgate_assert A serial-contains 'exec: loaded GOSH.ELF'
vgate_assert A serial-contains 'note: open id=2'
vgate_assert A serial-contains 'note: not-tab-aware (shim or WND desktop)'
vgate_assert A serial-contains 'note: ready'
# M191c (#3244): the shared appkit find overlay adopts NOTE — after the
# save (caret still at col 5 for the cursor assert below), ctrl-f docks
# the bar, 'b' scans the typed "abcde" incrementally, Return lands the
# caret on the hit, Escape closes.
vgate_assert A serial-contains 'note: find bar'
vgate_assert A serial-contains "note: find 'b' hit=1/1"
vgate_assert A serial-contains 'note: saved ok n=5'
vgate_assert A serial-contains 'note: cursor line=1 col=5 n=5'
vgate_assert A serial-contains 'input: armed=1 fifo=0/64 dropped=0 events=6'
vgate_assert A serial-contains 'dui: windows=5 focused=2'
vgate_assert A serial-absent '[EXC] parking:'

vgate_assert A snapshot 'gpu-screen-after' <<'PY'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
pos = 8; idat = b''; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b'IHDR':
        w, h, bd, ct = struct.unpack('>IIBB', data[:10])
    elif typ == b'IDAT':
        idat += data
    pos += 12 + ln
raw = zlib.decompress(idat)
bpp = 4 if ct == 6 else 3
stride = w * bpp
out = bytearray(); prev = bytearray(stride); i = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]

# The NOTE.ELF surface is the native (56,56,512,384) window. The
# VMRunner screenshot is Retina (2x guest coordinates); count contrasting
# pixels across the surface rather than assuming a fixed screenshot palette.
# The serial cursor assertion above is the text-content proof.
bg = (25, 32, 37)
surface = 0
for y in range(112, 880, 4):
    for x in range(112, 1136, 4):
        r, g, b = px(x, y)
        if max(abs(r-bg[0]), abs(g-bg[1]), abs(b-bg[2])) > 24:
            surface += 1
print("contrasting samples in NOTE.ELF surface: %d" % surface)
assert surface >= 100, f"too few contrasting NOTE.ELF surface pixels: {surface}"
PY
