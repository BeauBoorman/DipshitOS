# live-win-syscall.spec -- claim 0487 (milestone six, card G6) class-B
#
# gate: the draw/window syscall seam + per-process ownership, live on real
# VZ.
#
# Two EL0 programs prove the seam end to end:
#   * WIN.BIN (open -> fill -> present -> exit 87) proves an EL0 program
#     can render a window, and — with per-process ownership — that the
#     window AUTO-CLOSES when its owner exits: the post-exit `win` report

vgate_name live-win-syscall "claim 0487 (milestone six, card G6) class-B"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec WIN.BIN
EOF

vgate_file script2.txt <<'EOF'
dui
syscalls
exec WINLOOP.BIN
EOF

vgate_file script3.txt <<'EOF'
dui
syscalls
dui list 2
dui list 0
echo win-syscall-settled
EOF

vgate_run 01 -- --display --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --snapshot-after "win-syscall-settled" --snapshot-out '$RUN_DIR/snap' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after "procs WIN.BIN exited status=87" --script3 '$RUN_DIR/script3.txt' --script3-after "winloop: loop ok" --script-expect "timer heartbeat ticks=20 irq=20 poll=0" --timeout 60

vgate_assert 01 serial-contains 'win: fill ok'
vgate_assert 01 serial-contains 'win: present ok'
vgate_assert 01 serial-contains 'procs WIN.BIN exited status=87'
vgate_assert 01 serial-contains 'dui: windows=4'
vgate_assert 01 serial-contains 'winloop: loop ok'
vgate_assert 01 serial-contains 'dui: windows=5'
vgate_assert 01 serial-contains 'dui[4]: user user rect=64,64,512,384'
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented=96'
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui\[4\]: user user rect=64,64,512,384 .* owner=2', ser), "owner user check failed"
assert re.search(r'dui\[0\]: roadpops terminal .* owner=-', ser), "owner terminal check failed"
assert re.search(r'dui\[2\]: taskbar taskbar .* owner=-', ser), "owner taskbar check failed"
PY
vgate_assert 01 serial-contains 'dui list: pid=2 matches=1'
vgate_assert 01 serial-contains 'dui list: pid=0 matches=0'
vgate_assert 01 serial-contains '  12 sys_win_open calls=1'
vgate_assert 01 serial-contains '  15 sys_win_close calls=0'
vgate_assert 01 serial-contains '  12 sys_win_open calls=2'
vgate_assert 01 serial-contains '  13 sys_win_fill calls=8'
vgate_assert 01 serial-contains '  14 sys_win_present calls=2'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 snapshot 'snap-*.raw' <<'PY'
import sys
path = sys.argv[1]
data = open(path, 'rb').read()
assert len(data) == 1280 * 720 * 4, f"unexpected snapshot size {len(data)}"
w = 1280

def px(x, y):
    k = (y * w + x) * 4
    return (data[k+2], data[k+1], data[k]) # R, G, B

def classify(r, g, b):
    if r > 220 and g > 220 and b > 220:
        return 'white'       # 0xffffff -> (255,255,255)
    if g > 200 and b > 200 and r < 170:
        return 'cyan'        # 0x00ffff -> (0,255,255)
    if r > 180 and g < 110 and b < 110:
        return 'red'         # 0xff0000 -> (255,0,0)
    if b > r and b > g and max(r, g, b) < 110:
        return 'darkblue'    # 0x1a2b3c -> (26,43,60)
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

# The user window rect: logical (64,64,512,384).
UX0, UY0, UX1, UY1 = 64, 64, 576, 448

# (a) The three filled blocks sit at their expected spots:
# local (8,8), (64,8), (120,8) of size 48x48 -> centers (96,96), (152,96), (208,96).
red = classify(*px(96, 96))
cyan = classify(*px(152, 96))
white = classify(*px(208, 96))
print(f"blocks: red={red} cyan={cyan} white={white}")
if red != 'red':
    sys.exit(f"FAIL: the red block is not red at its spot ({red}) — the fill did not land")
if cyan != 'cyan':
    sys.exit(f"FAIL: the cyan block is not cyan at its spot ({cyan}) — the fill did not land")
if white != 'white':
    sys.exit(f"FAIL: the white block is not white at its spot ({white}) — the fill did not land")

# (b) The background is the dark-blue fill (0x1a2b3c), dominant in the client rect.
body = region(UX0 + 8, UY0 + 64, UX1 - 8, UY1 - 8)
fb = frac(body, 'darkblue')
print(f"user window body: {body} darkblue={fb:.3f}")
if fb < 0.60:
    sys.exit("FAIL: the user window background is not the dark-blue fill (the window did not render)")

# (c) NO green (terminal foreground) inside the user window client area — the
# opaque back-buffer covers the terminal beneath it (z-order proof).
whole = region(UX0 + 8, UY0 + 20, UX1 - 8, UY1 - 8, step=2)
if whole.get('green', 0) != 0:
    sys.exit(f"FAIL: terminal foreground visible inside the user window rect ({whole.get('green',0)} green) — the window did not cover the terminal")

print("PASS: the user window's own rendered content (dark-blue background + red/cyan/white blocks) sits in its rect over the terminal, with no terminal foreground showing through")
PY
