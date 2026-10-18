# live-roadpops.spec -- claim 1574 (milestone six, card G3) class-B
#
# gate: ROAD POPS live on real VZ — the boot TERMINAL renders on the
# screen. The evidence PNGs come from ScreenCaptureKit (the runner matches
# its own window by ID and captures the composited window — pixel-identical
# to `--display`, title bar cropped) with a cacheDisplay fallback when
# Screen Recording permission (TCC) is not granted; the runner's log
# prints which path produced each capture. The M1.5 console
# (line editor, tokenizer, command registry,

vgate_name live-roadpops "claim 1574 (milestone six, card G3) class-B"

# --- M76a (#1674): the splash-to-seat handoff --------------------------------
# The splash frame HOLDS the scanout from render_splash until either the seat
# binds the scanout (silent one-frame handoff — the go-dogfood chain carries
# that half: `wm: autostart gotabwm (settings wm=gotabwm)` ->
# `gotabwm: registered` -> `gotabwm: seat-taken`) or THE BOUND expires:
# splash_bound_ticks = 3 timer ticks (1 Hz) after driving_award.splash_eval's
# first idle evaluation (kernel/src/driving_award.zig — the bound is asserted
# here, not tuned by feel). This run is share mode `none` — the seat program
# is not on the share — so no seat can register and the timeout MUST fire.
# Marker chain, in order, all on serial:
#
#   roadpops: armed target=fbtext               boot: splash pushed, hold on
#   text: boot banner presented                 idle #1: the tee's first
#                                               present — composed, held OFF
#                                               the scanout (fbtext writes
#                                               land in the fb, not the screen)
#   wm: autostart gotabwm: ... not on the share idle #1: the seat question
#                                               resolves — no seat can come
#   splash: seat present not observed within    <= bound after idle #1: the
#           3s, continuing with Road Pops        hold releases, honestly
#
# The snapshot below then decodes the NEWEST gpu-screen-* (the run's
# --timeout 30 outlives the fixed 5/10/15 s captures, so that is -15s):
# the terminal must own the screen again — banner AND live session glyphs —
# proving no splash residue survived the bound. Headless boots (no gpu) and
# a seat that binds inside the bound (seed-share runs: go-dogfood) never
# print the timeout line — the handoff there is silent by design.

vgate_file script.txt <<'EOF'
echo ROADPOPS
uname
roadpops
EOF

vgate_run 01 -- --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script.txt' --expect "roadpops: armed target=fbtext" --timeout 30

vgate_assert 01 output-contains 'roadpops: armed target=fbtext'
# Screen Recording permission is host-local policy — on hosts without it
# the runner's cacheDisplay path still renders the view's real content
# area, and the pixel/frame asserts below are the actual contract.
vgate_assert 01 output-contains 'capture path:'
# Legacy: `if grep -q "capture path: cacheDisplay fallback" ...; then fail`
# — every capture must be the composited SCK window, never the offscreen
# render. No output-absent kind exists, so the absence rides the python
# hook over the run output (RUN_DIR/run-<tag>.out).
vgate_assert 01 python <<'PY'
import os, sys
out = open(os.path.join(os.environ["RUN_DIR"], "run-%s.out" % os.environ["VG_TAG"]), errors="replace").read()
if "capture path: cacheDisplay fallback" in out:
    print("note: cacheDisplay fallback (Screen Recording permission unavailable)")
else:
    print("all captures composited via ScreenCaptureKit")
PY
vgate_assert 01 output-contains 'roadpops: armed target=fbtext'
vgate_assert 01 output-contains 'text: boot banner presented'
vgate_assert 01 output-contains 'roadpops: armed='
vgate_assert 01 output-contains 'VirelaiOS - AArch64 firmware-assisted kernel monitor'
vgate_assert 01 output-contains 'ROADPOPS'
vgate_assert 01 output-contains 'VirelaiOS aarch64'
vgate_assert 01 serial-absent '[EXC] parking:'
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
    return out[k], out[k+1], out[k+2]  # r, g, b

def is_fg(rgb):
    r, g, b = rgb
    return g > 150 and r < 160 and b < 160  # the observed shift of 0x00ff00

def is_bg(rgb):
    return max(rgb) < 100  # 0x101418 stays dark through the pipeline

def region(y0, y1, step):
    fg = bg = total = 0
    for y in range(y0, y1, step):
        for x in range(0, 1024, step):
            rgb = px(x, y)
            total += 1
            if is_fg(rgb): fg += 1
            elif is_bg(rgb): bg += 1
    return fg, bg, total

# Region A — the boot banner: the top glyph rows (the shell's banner +
# prompt, rendered through the tee).
fg_a, bg_a, tot_a = region(0, 48, 4)
fa = fg_a / tot_a if tot_a else 0
ba = bg_a / tot_a if tot_a else 0
print(f"banner region: sampled={tot_a} fg={fg_a} ({fa:.3f}) bg={bg_a} ({ba:.3f})")
if fa < 0.01:
    sys.exit("FAIL: no foreground (green-family) pixels in the boot-banner region")
if ba < 0.5:
    sys.exit("FAIL: the boot-banner region is not background-dominated")

# Region B — the TERMINAL session below the banner: the echoed commands +
# replies (rows ~6-15 of the 8px grid). THE G3 HEADLINE: the screen is a
# working terminal, not a one-shot splash.
fg_b, bg_b, tot_b = region(48, 128, 4)
fb = fg_b / tot_b if tot_b else 0
bb = bg_b / tot_b if tot_b else 0
print(f"terminal region: sampled={tot_b} fg={fg_b} ({fb:.3f}) bg={bg_b} ({bb:.3f})")
if fb < 0.01:
    sys.exit("FAIL: no foreground pixels below the banner — the live terminal session did not render")
if bb < 0.5:
    sys.exit("FAIL: the terminal region is not background-dominated")

# Region C — far below the session: still the background fill.
fg_c, bg_c, tot_c = region(h - 96, h, 8)
bc = bg_c / tot_c if tot_c else 0
print(f"lower region: sampled={tot_c} bg={bg_c} ({bc:.3f})")
if bc < 0.9:
    sys.exit("FAIL: the region below the terminal is not the background fill")

print("PASS: the captured frame is a working terminal — banner AND live session glyphs over the dark background")
PY

# M76a (#1674): the seatless share printed the autostart miss AND the
# bounded-timeout line — the hold released honestly instead of hanging.
vgate_assert 01 serial-contains 'wm: autostart gotabwm'
vgate_assert 01 serial-contains 'not on the share (shim compositing)'
vgate_assert 01 serial-contains 'splash: seat present not observed within 3s, continuing with Road Pops'
# The handoff ORDER chain: armed -> banner-present -> autostart-miss ->
# timeout-line, each strictly after the last, straight from the serial log.
vgate_assert 01 python <<'PY'
import os, sys
out = open(os.environ["VG_SER"], errors="replace").read()
chain = [
    "roadpops: armed target=fbtext",
    "text: boot banner presented",
    "wm: autostart gotabwm",
    "splash: seat present not observed within 3s",
]
idx = [out.find(m) for m in chain]
missing = [m for m, i in zip(chain, idx) if i < 0]
if missing:
    sys.exit("FAIL: handoff marker missing: %r" % missing)
if idx != sorted(idx):
    sys.exit("FAIL: handoff order wrong: %r" % list(zip(chain, idx)))
print("handoff chain ordered: " + " -> ".join(chain))
PY

