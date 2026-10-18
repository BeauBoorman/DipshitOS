# live-m21-tile-master.spec -- claim 8777: M21 W1 tiling + W2 master swap

vgate_name live-m21-tile-master "claim 8777: M21 W1 tiling + W2 master swap"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script1.txt <<'EOF'
exec M21DEMO.BIN
EOF

vgate_file script2a.txt <<'EOF'
dui tile 2
dui tile 3
dui
EOF

vgate_file script2b.txt <<'EOF'
dui tile 2
dui tile 3
dui
dui master
dui
EOF

# --- run A (W1): tile split ---
vgate_run A -- \
    --display --screen '$RUN_DIR/gpu-screen' \
    --screenshot-after "timer heartbeat ticks=20" \
    --script '$RUN_DIR/script1.txt' \
    --script2 '$RUN_DIR/script2a.txt' --script2-after "m21demo: loop ok" \
    --script-expect "timer heartbeat ticks=20 irq=20 poll=0" \
    --timeout 90

vgate_assert A serial-contains "m21demo: open-a id=2"
vgate_assert A serial-contains "m21demo: fill-a ok"
vgate_assert A serial-contains "m21demo: present-a ok"
vgate_assert A serial-contains "m21demo: open-b id=3"
vgate_assert A serial-contains "m21demo: fill-b ok"
vgate_assert A serial-contains "m21demo: present-b ok"
vgate_assert A serial-contains "m21demo: loop ok"
vgate_assert A serial-contains "dui tile: id=2 mode=on master=2"
vgate_assert A serial-contains "dui tile: id=3 mode=on master=2 stack=3"
vgate_assert A serial-contains "dui: tiling=on master=2 stack=3 side=left"
vgate_assert A serial-absent "[EXC] parking:"

vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui\[[0-9]+\]: user user rect=24,0,837,700 ', ser), "master rect missing"
assert re.search(r'dui\[[0-9]+\]: user user rect=861,0,419,700 ', ser), "detail rect missing"
PY

vgate_assert A snapshot 'gpu-screen-after*' <<'PY'
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

def classify(r, g, b):
    if r > 200 and g > 200 and b > 200: return 'white'
    if (g > 50 and b > 50 and g > r + 15 and b > r + 15) or (g > 160 and b > 160 and r < 170): return 'cyan'
    if (r > 50 and r > g + 15 and r > b + 15) or (r > 140 and g < 130 and b < 130): return 'red'
    if (b > r + 5 and b > g + 5 and max(r, g, b) < 130) or (b > 30 and b > r and b > g): return 'darkblue'
    if g > 140 and r < 160 and b < 160: return 'green'
    return 'other'

def region(x0, y0, x1, y1, step=4):
    counts = {}
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            k = classify(*px(x, y))
            counts[k] = counts.get(k, 0) + 1
    return counts

def frac(counts, key):
    tot = sum(counts.values())
    return (counts.get(key, 0) / tot) if tot else 0.0

red = classify(*px(80, 64))
assert red == 'red', f"A's red block not at master origin ({red})"
cyan = classify(*px(1750, 64))
assert cyan == 'cyan', f"B's cyan block not at detail origin ({cyan})"
body_a = region(60, 180, 1050, 740)
assert frac(body_a, 'darkblue') >= 0.60, f"A not darkblue dominant: {body_a}"
body_b = region(1740, 180, 2540, 740)
assert frac(body_b, 'other') >= 0.60, f"B not black dominant: {body_b}"
PY

# --- run B (W2): swapped ---
vgate_run B -- \
    --display --screen '$RUN_DIR/gpu-screen' \
    --screenshot-after "timer heartbeat ticks=20" \
    --script '$RUN_DIR/script1.txt' \
    --script2 '$RUN_DIR/script2b.txt' --script2-after "m21demo: loop ok" \
    --script-expect "timer heartbeat ticks=20 irq=20 poll=0" \
    --timeout 90

vgate_assert B serial-contains "dui master: side=right master=3 stack=2"
vgate_assert B serial-contains "dui: tiling=on master=3 stack=2 side=right"
vgate_assert B serial-absent "[EXC] parking:"

vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui\[[0-9]+\]: user user rect=24,0,419,700 ', ser), "detail rect missing"
assert re.search(r'dui\[[0-9]+\]: user user rect=443,0,837,700 ', ser), "master rect missing"
PY

vgate_assert B snapshot 'gpu-screen-after*' <<'PY'
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

def classify(r, g, b):
    if r > 200 and g > 200 and b > 200: return 'white'
    if (g > 50 and b > 50 and g > r + 15 and b > r + 15) or (g > 160 and b > 160 and r < 170): return 'cyan'
    if (r > 50 and r > g + 15 and r > b + 15) or (r > 140 and g < 130 and b < 130): return 'red'
    if (b > r + 5 and b > g + 5 and max(r, g, b) < 130) or (b > 30 and b > r and b > g): return 'darkblue'
    if g > 140 and r < 160 and b < 160: return 'green'
    return 'other'

def region(x0, y0, x1, y1, step=4):
    counts = {}
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            k = classify(*px(x, y))
            counts[k] = counts.get(k, 0) + 1
    return counts

def frac(counts, key):
    tot = sum(counts.values())
    return (counts.get(key, 0) / tot) if tot else 0.0

red = classify(*px(80, 64))
assert red == 'red', f"A's red block missing from detail origin ({red})"
cyan_new = classify(*px(914, 64))
assert cyan_new == 'cyan', f"B's cyan block not at swapped master origin ({cyan_new})"
cyan_old = classify(*px(1750, 64))
assert cyan_old != 'cyan', "B's cyan block still at old detail spot"
old_strip = region(1900, 160, 2540, 740)
assert not old_strip.get('cyan', 0), f"cyan still in old detail strip: {old_strip}"
body_b = region(900, 180, 1890, 740)
assert frac(body_b, 'other') >= 0.60, f"B not black dominant: {body_b}"
body_a = region(60, 180, 1050, 740)
assert frac(body_a, 'darkblue') >= 0.60, f"A not darkblue dominant: {body_a}"
PY
