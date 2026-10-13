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
                 ("image/fonts/NotoSansJP-Regular.ttf", "NOTOCJK.TTF")):
    if not os.path.exists(src):
        sys.exit("missing font payload: " + src)
    shutil.copy(src, os.path.join(share, dst))
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
# (faces=9), the CJK line reaches NOTOCJK, the serif-only runes in the
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
vgate_assert 03 serial-contains 'fonts: manifest=ok faces=9'
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
vgate_assert 04 serial-contains 'fonts: manifest=ok faces=9'
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
