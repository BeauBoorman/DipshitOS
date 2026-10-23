# WEB TrueType/depth/image regressions at the frozen M93 presentation.
# Owner authorized the physical-pixel re-pin and approved all ten host-generated
# expectations. Exact RGB SHA-256 replaces impossible old near-native counts.
# Native font metrics, font-removal falsification and every behavior boot remain.
# No guest capture is a golden. Gate-only root artifacts retain guest WEB.ELF identity.
# Prerequisite: bash tools/go/build-web.sh browser WEB --gate
#
# M99m (#2190): the share now also stages FONTS.TXT, CHROME.TTF and the two
# coverage faces, so runs enter the M99l manifest path. Runs 03/04 are the
# coverage boots — they must precede 05, whose `vf rm` deletions persist on
# the share for the rest of the gate.
# M99o (#2192): INTERBI.TTF stages beside the other faces, the manifest pins
# faces=9, and run 03's COVER.HTML carries a font-weight:700;font-style:italic
# line so the gate watches it resolve to the dedicated face (bi-resolve).
# M178a (#3144): NOTOHEB.TTF joins the manifest (faces=10) and run 10 proves
# the bidi path on hardware. Runs 04/05 delete fonts through vf rm, so run 10
# restores what it needs by vf clone of the BAK-* copies staged at setup.

vgate_name live-web-ttf "WEB: native font metrics and exact M93 typography/table/image/fallback presentation"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-oliver.txt <<'EOF'
exec WEB.ELF /host/OLIVER.HTML
EOF
vgate_file script-depth.txt <<'EOF'
exec WEB.ELF /host/DEPTH.HTML
EOF
vgate_file script-cover.txt <<'EOF'
exec WEB.ELF /host/COVER.HTML
EOF
vgate_file script-cover-noface.txt <<'EOF'
vf rm NOTOSERF.TTF
vf rm NOTOCJK.TTF
vf ls
exec WEB.ELF /host/COVER.HTML
EOF
vgate_file script-nofont.txt <<'EOF'
vf rm INTER.TTF
vf rm INTERB.TTF
vf rm INTERI.TTF
vf rm INTERBI.TTF
vf rm FIRACODE.TTF
vf rm CHROME.TTF
vf rm FONTS.TXT
vf ls
exec WEB.ELF /host/OLIVER.HTML
EOF
vgate_file script-lists.txt <<'EOF'
exec WEB.ELF /host/LISTS.HTML
EOF
vgate_file script-png.txt <<'EOF'
exec WEB.ELF /host/PNG.HTML
EOF

vgate_setup_python <<'PY'
import binascii, os, shutil, struct, sys, zlib
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "WEB-GATE.ELF")
if not os.path.exists(src):
    sys.exit("build first: bash tools/go/build-web.sh browser WEB --gate")
shutil.copy(src, os.path.join(share, "WEB.ELF"))
shutil.copy(os.path.join("tests", "oliver-spike", "expect.html"), os.path.join(share, "OLIVER.HTML"))
for face in ("INTER.TTF", "INTERB.TTF", "INTERI.TTF", "INTERBI.TTF", "FIRACODE.TTF"):
    if not os.path.exists(os.path.join(share, face)):
        sys.exit("missing seeded face: " + face)
# M99m (#2190): the seeder still drops only the four original faces, so the
# manifest, the chrome face and the two coverage faces stage here — same
# names session.sh uses.
for src, dst in (("image/fonts/fonts.txt", "FONTS.TXT"),
                 ("image/fonts/VirelaiChrome-Regular.ttf", "CHROME.TTF"),
                 ("image/fonts/NotoSerif-Regular.ttf", "NOTOSERF.TTF"),
                 ("image/fonts/NotoSansJP-Regular.ttf", "NOTOCJK.TTF"),
                 ("image/fonts/NotoSansHebrew-Regular.ttf", "NOTOHEB.TTF")):
    if not os.path.exists(src):
        sys.exit("missing font payload: " + src)
    shutil.copy(src, os.path.join(share, dst))
# M178a run 10 follows the deletion runs, which leave the share fontless:
# these BAK-* copies are never rm'd, and run 10's script vf-clones them back
# into place before exec'ing BIDI.HTML.
for src, dst in (("image/fonts/fonts.txt", "BAK-FONTS.TXT"),
                 ("image/fonts/Inter-Regular.ttf", "BAK-INTER.TTF"),
                 ("image/fonts/NotoSansHebrew-Regular.ttf", "BAK-NOTOHEB.TTF")):
    shutil.copy(src, os.path.join(share, dst))
# The bidi page: an RTL-paragraph word, single-letter references for the
# probe's column signatures, a bracket-mirror check, and the card's mixed
# line. Numeric entities keep the fixture ASCII.
open(os.path.join(share, "BIDI.HTML"), "wb").write(
    b"<h4>bidi</h4>"
    b"<p>&#x5D0;&#x5D1;&#x5D2;&#x5D3;&#x5D4;</p>"
    b"<p>&#x5D4;&#x5D3;&#x5D2;&#x5D1;&#x5D0;</p>"
    b"<p>&#x5D0;</p>"
    b"<p>abc &#x5D0;&#x5D1;&#x5D2; (1) def</p>"
    b"<p>abc &#x5D2;&#x5D1;&#x5D0; (1) def</p>"
    b"<p>(&#x5D0;)</p>"
    b"<p>(x)</p>")
colors = [(0x11, 0x7f, 0x33), (0xd0, 0x33, 0x99),
          (0x22, 0x66, 0xdd), (0xee, 0xcc, 0x00)]
qoi = bytearray(b"qoif") + struct.pack(">II", 32, 32) + bytes([4, 0])
rows = bytearray()
for y in range(32):
    rows.append(0)
    for x in range(32):
        c = colors[(y // 16) * 2 + x // 16]
        qoi.extend((0xfe, *c))
        rows.extend((*c, 255))
qoi.extend((0, 0, 0, 0, 0, 0, 0, 1))
def chunk(kind, body):
    return (struct.pack(">I", len(body)) + kind + body +
            struct.pack(">I", binascii.crc32(kind + body) & 0xffffffff))
png = (b"\x89PNG\r\n\x1a\n" +
       chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 6, 0, 0, 0)) +
       chunk(b"IDAT", zlib.compress(bytes(rows))) + chunk(b"IEND", b""))
open(os.path.join(share, "SWATCH.QOI"), "wb").write(qoi)
open(os.path.join(share, "SWATCH.PNG"), "wb").write(png)
depth = (b"<p>MMMMMMMM</p><p><strong>MMMMMMMM</strong></p><h4>Depth</h4>"
         b"<table><thead><tr><th>Left</th><th>Right</th></tr></thead>"
         b"<tbody><tr><td>one</td><td>two</td></tr></tbody></table>"
         b'<p>An image:</p><img src="SWATCH.QOI" alt="swatch">'
         b'<p><a href="NEXT.HTML">a link</a></p>')
lists = (b"<h4>Lists</h4><dl><dt>term</dt><dd>definition sits indented</dd></dl>"
         b'<p><img src="NOPE.QOI" alt="missing"></p>')
open(os.path.join(share, "DEPTH.HTML"), "wb").write(depth)
open(os.path.join(share, "LISTS.HTML"), "wb").write(lists)
open(os.path.join(share, "PNG.HTML"), "wb").write(
    b'<img src="SWATCH.PNG" width="32" height="32" alt="guest PNG">')
# M99m coverage page: kyōiku kanji + kana only NOTOCJK covers, then ℔ and the
# ﬁ ligature — runes only NOTOSERF covers — inside a font-family:serif block.
# M99o adds a font-weight:700;font-style:italic line, the CSS that must
# resolve to INTERBI.TTF. A miss anywhere counts on `fonts: notdef`; real
# glyphs paint real ink.
open(os.path.join(share, "COVER.HTML"), "wb").write(
    b"<h4>coverage</h4>"
    b"<p>cjk &#x65e5;&#x672c;&#x8a9e; &#x3042;&#x3044; &#x30ab;&#x30ad;</p>"
    b'<p style="font-family:serif">serif &#x2114;&#xfb01;</p>'
    b'<p style="font-weight:700;font-style:italic">bold italic ink</p>')
print("M93f staged separately tagged WEB and original QOI/PNG/HTML fixtures")
PY

# 01: real faces. The metric markers remain native CSS/legacy font facts;
# the exact presentation hash proves actual text, not a chrome rectangle.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script-oliver.txt' \
    --snapshot-after 'web: settled' --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 01 serial-contains 'web: open id='
vgate_assert 01 serial-contains 'web: parse nodes='
vgate_assert 01 serial-contains 'web: layout blocks='
vgate_assert 01 serial-contains 'web: url /host/OLIVER.HTML'
vgate_assert 01 serial-contains 'web: paint items='
vgate_assert 01 serial-contains 'web: settled'
vgate_assert 01 serial-contains 'web: repaint items='
vgate_assert 01 serial-contains 'web: ready'
vgate_assert 01 serial-contains 'web: budget startup-ms='
vgate_assert 01 serial-absent 'web: budget over'
vgate_assert 01 serial-absent 'web: error'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-contains 'tls: roots virelai-gate-roots-2026-09-14'
vgate_assert 01 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 01 serial-absent 'web: fonts bitmap8x8'
vgate_assert 01 serial-contains 'web: text face=truetype(inter+firacode) proportional=yes'
vgate_assert 01 serial-contains ' body-lineh=18'
vgate_assert 01 serial-contains ' h1-lineh=33'
vgate_assert 01 serial-contains ' mono-lineh=17'
vgate_assert 01 serial-contains ' adv-i=3'
vgate_assert 01 serial-contains ' adv-W=13'
vgate_assert 01 serial-contains ' adv-space=4'
vgate_assert 01 serial-contains ' bold-face=yes'
vgate_assert 01 serial-contains ' bold-heavier=yes'
vgate_assert 01 serial-contains ' italic-face=yes'
vgate_assert 01 serial-contains ' bi-face=yes'
vgate_assert 01 serial-contains ' bi-resolve=bolditalic'
vgate_assert 01 serial-absent 'proportional=no'
vgate_assert 01 serial-absent 'adv-i=8'
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'oliver'])
PY

# 02: Regular/Bold text, table, decoded QOI quadrants, and link.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-02' --script '$RUN_DIR/script-depth.txt' \
    --snapshot-after 'web: settled' --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 02 serial-absent 'web: budget over'
vgate_assert 02 serial-contains 'web: url /host/DEPTH.HTML'
vgate_assert 02 serial-contains 'web: parse nodes='
vgate_assert 02 serial-contains 'web: layout blocks='
vgate_assert 02 serial-contains 'web: settled'
vgate_assert 02 serial-contains 'web: repaint items='
vgate_assert 02 serial-contains 'web: ready'
vgate_assert 02 serial-contains 'web: fonts truetype(inter+firacode)'
vgate_assert 02 serial-contains ' bold-face=yes'
vgate_assert 02 serial-contains ' bold-heavier=yes'
vgate_assert 02 serial-absent 'web: error'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 snapshot 'snap-02-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'depth'])
PY

# 03: M99m coverage faces, and M99o's bold-italic. The manifest is honored
# (faces=10), the CJK line reaches NOTOCJK, the serif-only runes in the
# font-family:serif block reach NOTOSERF through the ui cascade, and the
# font-weight:700;font-style:italic line resolves the dedicated face — the
# engine's own bi-resolve marker says so. No rune exhausts its chain, so
# `fonts: notdef` never speaks, and the page paints real ink (the probe
# counts non-background pixels in the page viewport; .notdef cannot satisfy
# the no-notdef marker).
vgate_run 03 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-03' --script '$RUN_DIR/script-cover.txt' \
    --snapshot-after 'web: settled' --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 03 serial-absent 'web: budget over'
vgate_assert 03 serial-contains 'web: url /host/COVER.HTML'
vgate_assert 03 serial-contains 'web: parse nodes='
vgate_assert 03 serial-contains 'web: layout blocks='
vgate_assert 03 serial-contains 'web: settled'
vgate_assert 03 serial-contains 'web: repaint items='
vgate_assert 03 serial-contains 'web: ready'
vgate_assert 03 serial-contains 'fonts: manifest=ok faces=10'
# M99z (#2194): the probe's serif fields pin the M99p end-to-end — the serif
# role is loaded (serif=truetype), the face resolved (serif-face=yes), and a
# {serif} style resolves by name to the serif face, not Inter
# (serif-resolve=serif). COVER.HTML's `font-family:serif` block and its CJK
# line are the in-page half of that evidence; `fonts: notdef` staying silent
# is what proves neither rune set painted tofu.
vgate_assert 03 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype serif=truetype'
vgate_assert 03 serial-contains ' serif-face=yes'
vgate_assert 03 serial-contains ' serif-resolve=serif'
vgate_assert 03 serial-contains ' bi-face=yes'
vgate_assert 03 serial-contains ' bi-resolve=bolditalic'
vgate_assert 03 serial-absent 'fonts: notdef='
vgate_assert 03 serial-absent 'web: error'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os, re, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
ser = Path(os.environ["VG_SER"]).read_text(errors="replace")
m = re.findall(r"^web: viewport css=1280x720 x=(\d+) y=(\d+) w=(\d+) h=(\d+) s=(\d+)$",
               ser, re.MULTILINE)
if not m:
    sys.exit("missing intact viewport marker")
x, y, w, h, _ = map(int, m[-1])
if (x, y, w, h) != (0, 64, 512, 288):
    sys.exit("wrong presentation geometry")
x, y = x + 40, y + 28
snaps = sorted(run.glob("snap-03-*.raw"))
if not snaps:
    sys.exit("no scanout snapshot")
raw = snaps[-1].read_bytes()
if len(raw) != 1280 * 720 * 4:
    sys.exit("scanout size mismatch")
bg_at = ((y + h - 4) * 1280 + x + w - 4) * 4
bg = raw[bg_at:bg_at + 3]
ink = 0
for yy in range(y, y + h):
    row = yy * 1280 * 4
    for xx in range(x, x + w):
        if raw[row + xx * 4:row + xx * 4 + 3] != bg:
            ink += 1
print("coverage viewport ink pixels:", ink, "bg:", bg.hex())
if ink < 500:
    sys.exit("coverage page painted too little ink for 12 real glyphs")
# M99z (#2194): the card's per-family pixel evidence rides on the serial
# markers, not on pixel regions — `fonts: notdef` absent proves every rune
# (the CJK codepoints AND the serif-only ℔/ﬁ in the font-family:serif
# block) resolved to real coverage instead of tofu, `serif-resolve=serif`
# proves the serif run took the serif face, and the ink floor above proves
# the page painted them.
PY

# 04: fail-first mirror. The coverage faces are deleted through the real host
# file channel and the same page re-run: every CJK and serif-only rune
# exhausts its chain, so `fonts: notdef` counts them and the painted band
# differs from run 03's (tofu is not the real glyphs).
vgate_run 04 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-04' --script '$RUN_DIR/script-cover-noface.txt' \
    --snapshot-after 'web: settled' --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 04 serial-absent 'web: budget over'
vgate_assert 04 serial-contains 'web: url /host/COVER.HTML'
vgate_assert 04 serial-contains 'fonts: manifest=ok faces=10'
vgate_assert 04 serial-contains 'fonts: notdef='
vgate_assert 04 serial-contains 'web: ready'
vgate_assert 04 serial-absent 'web: error'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 python <<'PY'
import os, re, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
ser = Path(os.environ["VG_SER"]).read_text(errors="replace")
m = re.findall(r"^web: viewport css=1280x720 x=(\d+) y=(\d+) w=(\d+) h=(\d+) s=(\d+)$",
               ser, re.MULTILINE)
if not m:
    sys.exit("missing intact viewport marker")
x, y, w, h, _ = map(int, m[-1])
x, y = x + 40, y + 28
def crop(p):
    raw = Path(p).read_bytes()
    if len(raw) != 1280 * 720 * 4:
        sys.exit("scanout size mismatch: " + str(p))
    return b"".join(raw[(yy * 1280 + x) * 4:(yy * 1280 + x + w) * 4]
                    for yy in range(y, y + h))
with_faces = sorted(run.glob("snap-03-*.raw"))
no_faces = sorted(run.glob("snap-04-*.raw"))
if not with_faces or not no_faces:
    sys.exit("missing a scanout to compare")
a, b = crop(with_faces[-1]), crop(no_faces[-1])
print("with-faces crop bytes:", len(a), "identical to no-faces:", a == b)
if a == b:
    sys.exit("deleting the coverage faces changed no pixels")
PY

# 05: remove every face through the actual host file channel. Distinct grid
# hash is the falsification: a grid cannot pass the real-face expectation.
vgate_run 05 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-05' --script '$RUN_DIR/script-nofont.txt' \
    --snapshot-after 'web: settled' --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 05 serial-absent 'web: budget over'
vgate_assert 05 serial-contains 'web: fonts bitmap8x8 ui=missing mono=missing serif=missing'
vgate_assert 05 serial-contains 'web: text face=bitmap8x8 proportional=no'
vgate_assert 05 serial-contains ' bold-face=no'
vgate_assert 05 serial-contains ' italic-face=no'
vgate_assert 05 serial-contains ' bi-face=no'
vgate_assert 05 serial-contains ' bi-resolve=none'
vgate_assert 05 serial-contains ' serif-face=no'
vgate_assert 05 serial-contains ' serif-resolve=none'
vgate_assert 05 serial-contains ' adv-i=8'
vgate_assert 05 serial-contains ' adv-W=8'
vgate_assert 05 serial-contains ' h1-lineh=18'
vgate_assert 05 serial-absent 'proportional=yes'
vgate_assert 05 serial-contains 'web: parse nodes='
vgate_assert 05 serial-contains 'web: settled'
vgate_assert 05 serial-contains 'web: repaint items='
vgate_assert 05 serial-contains 'web: ready'
vgate_assert 05 serial-absent 'web: error'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 snapshot 'snap-05-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'oliver-grid'])
PY

# 06: definition-list indentation and visible missing-image alt box.
vgate_run 06 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-06' --script '$RUN_DIR/script-lists.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 06 serial-absent 'web: budget over'
vgate_assert 06 serial-contains 'web: url /host/LISTS.HTML'
vgate_assert 06 serial-contains 'web: parse nodes='
vgate_assert 06 serial-contains 'web: layout blocks='
vgate_assert 06 serial-contains 'web: settled'
vgate_assert 06 serial-absent 'web: error'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 snapshot 'snap-06-0.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'lists-grid'])
PY

# 07: real guest PNG decode; no face is needed. A placeholder cannot satisfy
# the exact host swatch hash or its four unique decoded colors.
vgate_run 07 -- \
    --screen '$RUN_DIR/screen' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-07' --script '$RUN_DIR/script-png.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 07 serial-contains 'web: url /host/PNG.HTML'
vgate_assert 07 serial-contains 'web: parse nodes='
vgate_assert 07 serial-contains 'web: layout blocks='
vgate_assert 07 serial-contains 'web: paint items='
vgate_assert 07 serial-contains 'web: repaint items='
vgate_assert 07 serial-contains 'web: ready'
vgate_assert 07 serial-absent 'web: error'
vgate_assert 07 serial-absent 'web: budget over'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 snapshot 'snap-07-*.raw' <<'PY'
import subprocess, sys
subprocess.check_call([sys.executable, 'user/go/browser/pixel_probe.py', sys.argv[1], 'png-grid'])
PY

# --- M123b (#2576) run 08: the blank viewport's shared empty state ---------
# `exec WEB.ELF` with NO target paints the start surface — since M123b that
# is the shared widgets.EmptyState plate through the fill-only virender
# (icon, headline, chord hints), not a fetched page, so `web: empty start`
# prints and the settle arc still lands (`repaint items=0` is the honest
# count for a surface that owns no layout).
vgate_file script-empty.txt <<'EOS'
exec WEB.ELF
EOS

vgate_run 08 -- \
    --screen '$RUN_DIR/screen-08' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-08' \
    --script '$RUN_DIR/script-empty.txt' \
    --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 08 serial-contains 'exec: loaded WEB.ELF'
vgate_assert 08 serial-contains 'web: open id='
vgate_assert 08 serial-contains 'web: empty start'
vgate_assert 08 serial-contains 'web: settled'
vgate_assert 08 serial-contains 'web: repaint items=0'
vgate_assert 08 serial-contains 'web: ready'
vgate_assert 08 serial-contains 'web: budget startup-ms='
vgate_assert 08 serial-absent 'web: error'
vgate_assert 08 serial-absent 'web: budget over'
vgate_assert 08 serial-absent '[EXC] parking:'

# The scanout (1280x720 BGRX): the 512x384 raw-shim window at (40,28) puts
# the presented viewport at x=40..552, y=92..380 — the empty-state plate is
# the Surface fill (34,45,53) covering it minus a 24px inset margin, with
# centred text rows inside (anything non-Surface/Border in the middle band).
vgate_assert 08 snapshot 'snap-08-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want %d" % (len(raw), need))

def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])

SURFACE = (0x22, 0x2d, 0x35)
BORDER = (0x33, 0x41, 0x55)
PAGEBG = (0x18, 0x20, 0x26)

plate = ring = textish = 0
for y in range(100, 375):
    for x in range(50, 545):
        c = px(x, y)
        if c == SURFACE:
            plate += 1
        elif c == BORDER:
            ring += 1
for y in range(150, 320):
    for x in range(80, 510):
        c = px(x, y)
        if c not in (SURFACE, BORDER, PAGEBG):
            textish += 1
print("web empty leg: plate=%d ring=%d interior-text=%d" % (plate, ring, textish))
assert plate >= 40000, "empty-state plate absent from the blank viewport"
assert ring >= 400, "empty-state border ring missing"
assert textish >= 50, "no empty-state text inside the viewport plate"
PY

# --- M123d (#2578) run 09: load failure -> shared error banner ------------
# WEB pointed at a file that does not exist lands on the error page AND the
# in-app banner: `web: banner load failed: file` is the raise marker the
# app prints when the strip stands. Escape dismisses it — `web: banner act
# dismiss` is the resolution. A permanent kind ("file") carries no Retry.
vgate_file script-banner.txt <<'EOS'
exec WEB.ELF /host/NOFILE.TXT
EOS

vgate_run 09 -- \
    --screen '$RUN_DIR/screen-09' --via-virtio \
    --script '$RUN_DIR/script-banner.txt' \
    --input-chords 'escape' \
    --input-chords-after 'web: banner load failed: file' \
    --script-expect 'web: banner act dismiss' --timeout 120

vgate_assert 09 serial-contains 'exec: loaded WEB.ELF'
vgate_assert 09 serial-contains 'web: error file'
vgate_assert 09 serial-contains 'web: banner load failed: file'
vgate_assert 09 serial-contains 'web: banner act dismiss'
vgate_assert 09 serial-absent 'web: banner act retry'
vgate_assert 09 serial-absent '[EXC] parking:'

# --- M178a (#3144) run 10: Hebrew + bidi after the deletion runs ----------
# The share is fontless after runs 04/05, so the script vf-clones the BAK-*
# copies back into place first: the manifest plus just the faces the page
# needs (INTER for Latin, NOTOHEB for Hebrew). `fonts: manifest=ok faces=10`
# counts manifest ROWS not loads — the four absent faces simply stay
# unloaded. `fonts: notdef` staying silent proves every painted rune —
# Hebrew included — resolved to real coverage, and the python probe pins the
# visual order: the RTL word's FIRST logical letter (alef) carries the
# right-edge column signature, its last (heh) the left edge, and the
# bracket-mirrored line starts with the same '(' columns the LTR reference
# line does.
vgate_file script-bidi.txt <<'EOS'
vf clone BAK-FONTS.TXT FONTS.TXT
vf clone BAK-INTER.TTF INTER.TTF
vf rm NOTOHEB.TTF
vf clone BAK-NOTOHEB.TTF NOTOHEB.TTF
exec WEB.ELF /host/BIDI.HTML
EOS

vgate_run 10 -- \
    --screen '$RUN_DIR/screen-10' --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-10' --script '$RUN_DIR/script-bidi.txt' \
    --snapshot-after 'web: settled' --snapshot-after 'web: repaint' \
    --script-expect 'web: ready' --timeout 120

vgate_assert 10 serial-absent 'web: budget over'
vgate_assert 10 serial-contains 'web: url /host/BIDI.HTML'
vgate_assert 10 serial-contains 'fonts: manifest=ok faces=10'
vgate_assert 10 serial-contains 'web: fonts truetype(inter) ui=truetype mono=missing serif=missing'
vgate_assert 10 serial-contains 'web: text face=truetype(inter) proportional=yes'
vgate_assert 10 serial-absent 'fonts: notdef='
vgate_assert 10 serial-contains 'web: ready'
vgate_assert 10 serial-absent 'web: error'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 python <<'PY'
import os, re, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
ser = Path(os.environ["VG_SER"]).read_text(errors="replace")
m = re.findall(r"^web: viewport css=1280x720 x=(\d+) y=(\d+) w=(\d+) h=(\d+) s=(\d+)$",
               ser, re.MULTILINE)
if not m:
    sys.exit("missing intact viewport marker")
x, y, w, h, _ = map(int, m[-1])
snaps = sorted(run.glob("snap-10-*.raw"))
if not snaps:
    sys.exit("no scanout snapshot")
raw = snaps[-1].read_bytes()
if len(raw) != 1280 * 720 * 4:
    sys.exit("scanout size mismatch")

# Ink = bright pixels (text on the dark page). The window sits near the
# marker's (x,y); page text lands just left of x+40 — scan a generous box
# and ignore columns bright over >60 rows (the scrollbar/chrome poles).
def ink(yy, xx):
    at = (yy * 1280 + xx) * 4
    return raw[at] + raw[at + 1] + raw[at + 2] > 300

X0, X1, Y0, Y1 = x + 28, x + w - 8, y + 16, y + h + 40
xs = [c for c in range(X0, X1)
      if sum(1 for r in range(Y0, Y1) if ink(r, c)) <= 60]
bands, cur = [], -1
for yy in range(Y0, Y1):
    if any(ink(yy, xx) for xx in xs):
        if cur < 0:
            cur = yy
    elif cur >= 0:
        bands.append((cur, yy)); cur = -1
if cur >= 0:
    bands.append((cur, Y1))
# merge a glyph line split by one empty row, drop 1-row specks
merged = [list(bands[0])] if bands else []
for b in bands[1:]:
    if b[0] - merged[-1][1] <= 3:
        merged[-1][1] = b[1]
    else:
        merged.append(list(b))
bands = [b for b in merged if b[1] - b[0] >= 3]
# h4 + seven <p> lines
if len(bands) != 8:
    sys.exit("want 8 text bands, found %d: %s" % (len(bands), bands))

def mask(b):
    t, bb = b
    cols = [xx for xx in range(X0, X1)
            if any(ink(yy, xx) for yy in range(t, bb))]
    return [[ink(yy, xx) for xx in range(cols[0], cols[-1] + 1)]
            for yy in range(t, bb)]

def flip(m):
    return [list(reversed(r)) for r in m]

def clusters(b):
    t, bb = b
    out, c = [], None
    for xx in range(X0, X1):
        if any(ink(yy, xx) for yy in range(t, bb)):
            c = [xx, xx] if c is None else [c[0], xx]
        elif c:
            out.append(tuple(c)); c = None
    if c:
        out.append(tuple(c))
    return out

# bands[1]=אבגדה and bands[2]=הדגבא are each other's logical reversal; both
# auto-resolve RTL, so the two painted lines must be exact horizontal
# mirrors — the Hebrew word ran right-to-left iff this holds.
if flip(mask(bands[1])) != mask(bands[2]):
    sys.exit("RTL word lines are not mirror images — run did not reverse")

# bands[4]/[5]: "abc אבג (1) def" vs "abc גבא (1) def" — the painted Hebrew
# groups (second whitespace-separated group) must likewise mirror.
def group(b, i):
    cs = clusters(b)
    if len(cs) != 4:
        sys.exit("mixed line has %d word groups, want 4: %s" % (len(cs), cs))
    g = cs[i]
    return [[ink(yy, xx) for xx in range(g[0], g[1] + 1)]
            for yy in range(b[0], b[1])]
if flip(group(bands[4], 1)) != group(bands[5], 1):
    sys.exit("mixed-line Hebrew groups are not mirror images")

# bands[6]/[7]: "(א)" in an RTL paragraph vs LTR "(x)". Mirroring (L4)
# means the RTL line's leftmost glyph is '(' — the SAME mask the LTR line
# opens with; an unmirrored close-paren would be its mirror image instead.
def submask(b, c):
    return [[ink(yy, xx) for xx in range(c[0], c[1] + 1)]
            for yy in range(b[0], b[1])]
lE = submask(bands[6], clusters(bands[6])[0])
lF = submask(bands[7], clusters(bands[7])[0])
H = min(len(lE), len(lF))
if lE[-H:] != lF[-H:]:
    sys.exit("RTL paren line does not open with '(' columns")
print("bidi run 10: RTL words mirror their logical reverse, mixed-line "
      "Hebrew mirrors too, parens mirrored")
PY
