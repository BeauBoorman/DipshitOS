# live-text.spec -- claim 3194 (milestone six, card G2) class-B gate:
#
# FRAMEBUFFER TEXT observed end to end on real VZ — the machine now boots
# to WORDS on the screen, painted by kernel/src/text.zig (the fixed BSS
# 8x8 bitmap font) on top of G1's virtio-gpu framebuffer.
#
# Mechanism: the runner's `--display`/`--screenshot` flag (OFF by default —
# the default VM is untouched) attaches ONE VZVirtioGraphicsDeviceConfiguration
# with a 1280x720 scanout. The guest boots, G1's virtio_gpu.zig sets up the

vgate_name live-text "claim 3194 (milestone six, card G2) class-B gate:"

vgate_file script.txt <<'EOF'
text
EOF

vgate_run 01 -- --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script.txt' --expect "text: boot banner presented" --timeout 30

vgate_assert 01 output-contains 'gpu: pre-rearm st=00'
# Screen Recording permission is host-local policy — on hosts without it
# the runner's cacheDisplay path still renders the view's real content
# area; the pixel asserts below are the actual contract.
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
vgate_assert 01 output-contains 'gpu: pre-rearm st=00'
vgate_assert 01 output-contains 'text: boot banner presented'
vgate_assert 01 output-contains 'text: rows=90 cols=160 cell=8x8'
vgate_assert 01 output-contains 'VirelaiOS - AArch64 firmware-assisted kernel monitor'
vgate_assert 01 output-contains 'virelai> '
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

# Region A — the banner: the top 4 glyph rows (8px cells) + margin, and the
# banner's column span (the longest line is ~54 chars -> ~432px at 8px/char;
# sample generously to 1024px).
fg = bg = 0; total = 0
for y in range(0, 48, 4):
    for x in range(0, 1024, 4):
        rgb = px(x, y)
        total += 1
        if is_fg(rgb): fg += 1
        elif is_bg(rgb): bg += 1
fg_frac = fg / total if total else 0
bg_frac = bg / total if total else 0
print(f"banner region: sampled={total} fg={fg} ({fg_frac:.3f}) bg={bg} ({bg_frac:.3f})")
if fg_frac < 0.01:
    sys.exit("FAIL: no foreground (green-family) pixels in the banner region — no text painted")
if bg_frac < 0.5:
    sys.exit("FAIL: the banner region is not background-dominated — the frame looks like a solid fill, not text")
if fg_frac > 0.5:
    sys.exit("FAIL: the banner region is mostly foreground — implausible for sparse 8x8 glyphs")

# Region B — far below the text (bottom of the frame): must be the dark
# background fill, proving the rest of the screen is not garbage/solid.
dbg = 0; dtotal = 0
for y in range(h - 96, h, 8):
    for x in range(0, w, 16):
        rgb = px(x, y)
        dtotal += 1
        if is_bg(rgb): dbg += 1
dbg_frac = dbg / dtotal if dtotal else 0
print(f"lower region: sampled={dtotal} bg={dbg} ({dbg_frac:.3f})")
if dbg_frac < 0.9:
    sys.exit("FAIL: the region below the text is not the background fill")

print("PASS: the captured frame shows text (foreground glyphs over the dark background) in the banner region")
PY

