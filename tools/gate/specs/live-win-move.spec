# live-win-move.spec -- claim 0487 (milestone six, card G6 move/raise
#
# follow-on) class-B gate: the window manager's MOVE/RESTACK surface, live
# on real VZ.
#
# WINMOVE.BIN (`user/src/winmove.zig`, the NINTH ESP user program) drives
# the ADR 0007 slots 16/17/18/19/20 (`sys_win_move` / `sys_win_raise` /
# `sys_win_get` / `sys_win_query` / `sys_win_set_visible`) entirely from EL0:
# open -> fill -> present -> move to (800,400) -> move to (1200,700) (the

vgate_name live-win-move "claim 0487 (milestone six, card G6 move/raise"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec WINMOVE.BIN
EOF

vgate_file script2.txt <<'EOF'
dui
syscalls
dui move 2 768 336
dui raise 2
EOF

# Issue #1024: the expect marker is the kernel's 1 Hz heartbeat tick 20 —
# GUEST virtual time — against a wall-clock --timeout. Under host load VZ
# virtual time dilates and tick 20 can arrive late; 60 s raced that dilation
# and failed fully-green runs (rc=1, every assert green). 120 s leaves 2x
# headroom; the marker itself gates the verdict, so the tail is bounded.
vgate_run 01 -- --display --screen '$RUN_DIR/gpu-screen' --screenshot-after "winmove: hide ok" --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after "winmove: loop ok" --script-expect "timer heartbeat ticks=20 irq=20 poll=0" --timeout 120

vgate_assert 01 serial-contains 'winmove: open id=2'
vgate_assert 01 serial-contains 'winmove: fill ok'
vgate_assert 01 serial-contains 'winmove: present ok'
vgate_assert 01 serial-contains 'winmove: move ok'
vgate_assert 01 serial-contains 'winmove: raise ok'
vgate_assert 01 serial-contains 'winmove: loop ok'
vgate_assert 01 serial-contains 'winmove: get 768,336,512,384'
vgate_assert 01 serial-contains 'winmove: query 768,336,512,384 z=4 focused=1 visible=1 dirty=1'
vgate_assert 01 serial-contains 'winmove: hide ok'
vgate_assert 01 serial-contains 'winmove: show ok'
vgate_assert 01 serial-contains 'dui: windows=5'
vgate_assert 01 serial-contains 'dui[4]: user user rect=768,336,512,384'
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui\[4\]: user user rect=768,336,512,384 .* owner=[0-9]+', ser), "owner check failed"
assert re.search(r'dui\[4\]: user user rect=768,336,512,384 dirty=[01] visible=1', ser), "visible check failed"
PY
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented=96'
vgate_assert 01 serial-contains '  16 sys_win_move calls=2'
vgate_assert 01 serial-contains '  17 sys_win_raise calls=1'
vgate_assert 01 serial-contains '  18 sys_win_get calls=1'
vgate_assert 01 serial-contains '  19 sys_win_query calls=1'
vgate_assert 01 serial-contains '  20 sys_win_set_visible calls=2'
vgate_assert 01 serial-contains '  14 sys_win_present calls=3'
vgate_assert 01 serial-contains '  15 sys_win_close calls=0'
vgate_assert 01 serial-contains 'dui move: moved=2 to 768,336'
vgate_assert 01 serial-contains 'dui raise: raised=2'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 snapshot 'gpu-screen-after' <<'PY'
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
    if r > 220 and g > 220 and b > 220:
        return 'white'
    if g > 200 and b > 200 and r < 170:
        return 'cyan'
    if r > 180 and g < 110 and b < 110:
        return 'red'
    if b > r and b > g and max(r, g, b) < 110:
        return 'darkblue'
    if g > 140 and r < 160 and b < 160:
        return 'green'
    return 'other'

def region(x0, y0, x1, y1, step=3):
    counts = {}
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            k = classify(*px(x, y))
            counts[k] = counts.get(k, 0) + 1
    return counts

# The CLAMPED window rect in retina coords: logical (768,336,512,384) x2.
NX0, NY0, NX1, NY1 = 1536, 672, 2560, 1440

# (a) The three blocks are GONE from their new spots (window-local (8,8),
# (64,8), (120,8) 48x48 -> retina centers (1600,736), (1712,736),
# (1824,736)).
h_red = classify(*px(1600, 736))
h_cyan = classify(*px(1712, 736))
h_white = classify(*px(1824, 736))
print(f"hidden blocks: red={h_red} cyan={h_cyan} white={h_white}")
if h_red == 'red' or h_cyan == 'cyan' or h_white == 'white':
    sys.exit(f"FAIL: a colored block still sits at the new spot while hidden ({h_red}/{h_cyan}/{h_white}) — the hide did not land")

# (b) No red/cyan/white anywhere in the clamped rect MINUS the taskbar
# strip (the bottom 20 logical px hold white tray glyphs of their own —
# observed 2026-08-24, claim 8777) — the window's OWN rendered content is
# gone (the terminal's slate background + green text is revealed beneath;
# both classify as darkblue/other here).
h_whole = region(NX0 + 4, NY0 + 4, NX1 - 4, NY1 - 48, step=2)
print(f"hidden whole rect: {h_whole}")
if h_whole.get('red', 0) or h_whole.get('cyan', 0) or h_whole.get('white', 0):
    sys.exit(f"FAIL: window content (red/cyan/white) still present in the clamped rect while hidden ({h_whole})")

print("PASS: the window's own rendered content is GONE from the clamped spot while hidden (the terminal beneath is revealed)")
PY
vgate_assert 01 snapshot 'gpu-screen-*' <<'PY'
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
    if r > 220 and g > 220 and b > 220:
        return 'white'       # 0xffffff -> (255,255,255)
    if g > 200 and b > 200 and r < 170:
        return 'cyan'        # 0x00ffff -> (117,251,253)
    if r > 180 and g < 110 and b < 110:
        return 'red'         # 0xff0000 -> (234,51,35)
    if b > r and b > g and max(r, g, b) < 110:
        return 'darkblue'    # 0x1a2b3c -> (30,43,59)
    if g > 140 and r < 160 and b < 160:
        return 'green'       # terminal foreground (0x00ff00 -> ~(80,174,52))
    return 'other'

def region(x0, y0, x1, y1, step=3):
    counts = {}
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            k = classify(*px(x, y))
            counts[k] = counts.get(k, 0) + 1
    return counts

def frac(counts, key):
    tot = sum(counts.values())
    return (counts.get(key, 0) / tot) if tot else 0.0

# The CLAMPED window rect in retina coords: logical (768,336,512,384) x2.
NX0, NY0, NX1, NY1 = 1536, 672, 2560, 1440

# (a) The three filled blocks sit at their expected spots at the NEW
# position (window-local (8,8), (64,8), (120,8) 48x48 -> retina centers
# (1600,736), (1712,736), (1824,736)).
new_red = classify(*px(1600, 736))
new_cyan = classify(*px(1712, 736))
new_white = classify(*px(1824, 736))
print(f"blocks-at-new: red={new_red} cyan={new_cyan} white={new_white}")
if new_red != 'red':
    sys.exit(f"FAIL: the red block is not red at its NEW spot ({new_red}) — the move did not land")
if new_cyan != 'cyan':
    sys.exit(f"FAIL: the cyan block is not cyan at its NEW spot ({new_cyan}) — the move did not land")
if new_white != 'white':
    sys.exit(f"FAIL: the white block is not white at its NEW spot ({new_white}) — the move did not land")

# (b) The background is the dark-blue fill, dominant in the NEW rect body
# (below the blocks).
body = region(NX0 + 8, NY0 + 128, NX1 - 8, NY1 - 8)
fb = frac(body, 'darkblue')
print(f"new window body: {body} darkblue={fb:.3f}")
if fb < 0.60:
    sys.exit("FAIL: the user window background is not dark-blue at the NEW position (the window did not render there)")

# (c) NO green (terminal foreground) inside the NEW rect — the opaque
# back-buffer covers the terminal beneath it (z-order proof).
whole = region(NX0 + 4, NY0 + 4, NX1 - 4, NY1 - 4, step=2)
if whole.get('green', 0) != 0:
    sys.exit(f"FAIL: terminal foreground visible inside the NEW window rect ({whole.get('green',0)} green)")

# (d) The OLD position (logical (64,64)) no longer shows the colored blocks
# — the window really MOVED away (the terminal is there now).
old_red = classify(*px(192, 192))
old_cyan = classify(*px(304, 192))
old_white = classify(*px(416, 192))
print(f"blocks-at-old: red={old_red} cyan={old_cyan} white={old_white}")
if old_red == 'red' or old_cyan == 'cyan' or old_white == 'white':
    sys.exit("FAIL: a colored block still sits at the OLD position — the window did not move off its original spot")

print("PASS: WINMOVE's own rendered content (dark-blue background + red/cyan/white blocks) is at the CLAMPED NEW position, with the old spot showing the terminal — the window really moved")
PY
