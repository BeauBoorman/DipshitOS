# go-reader.spec -- M143a (issue #2792) class-B gate: GOREADER.ELF, the
# Document mime's registered handler, opens a corpus-authored PDF on VZ.
#
# Run 01 is the product journey on a bare boot (no seat: the app's declared
# window blits 1:1 at (40,24), the kernel's 16px title band covers canvas
# rows 0..15, and the --cvc-snap scanout probes the hit band's blended
# pixels):
#   pagedown   -> the scroll-and-flip rule turns to page 2 (`page 2/3`)
#   =          -> one zoom-table step to 150% (`zoom z=150%`)
#   ctrl-f Z O O return -> the find bar searches the extracted text, lands
#     on the page-2 `ZOOKEEPER` hit and blends the accent band onto the
#     page (`find 'ZOO' hit=1/1 page=2`), where the snapshot probe counts it.
#
# Run 02 is the refusal leg: STROKE.PDF is the M89 corpus's pinned
# unsupported-stroke negative; the engine's UnsupportedStroke must reach
# the console AND the window (Danger-ink probe on the snapshot).
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goreader.sh   ->  .build/go/GOREADER.ELF
#
# exec-order: assert-proven -- both runs end on an rx- marker only the
# scripts print, and the stage/snapshot gates wait on the app's own
# markers; a program that never ran cannot pass.

vgate_name go-reader "M143a (#2792): GOREADER opens a corpus PDF - page nav, zoom, find-hit pixel, named refusal"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOREADER.ELF /host/READER/PAGES.PDF
EOF

vgate_file script2.txt <<'EOF'
echo rx-reader-journey-ok
EOF

vgate_file script-r.txt <<'EOF'
exec GOREADER.ELF /host/READER/STROKE.PDF
EOF

vgate_file script2-r.txt <<'EOF'
echo rx-reader-refuse-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
sys.path.insert(0, os.path.join(os.getcwd(), "tools", "pdf-proof"))
import corpus

rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOREADER.ELF")
if not os.path.exists(src):
    sys.exit("GOREADER.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goreader.sh")
shutil.copy(src, os.path.join(share, "GOREADER.ELF"))

rd_dir = os.path.join(share, "READER")
os.makedirs(rd_dir, exist_ok=True)

# A three-page 96x72pt (128x96px) Type3 text document. The font covers
# space + A-Z: every Difference name has a CharProc whose d1 width agrees
# with Widths, the same shape corpus.text() authors for the proof suite.
names = ["/Space"] + ["/" + chr(c) for c in range(ord('A'), ord('Z') + 1)]
diffs = b"[32 /Space 65 " + b" ".join(n.encode() for n in names[1:]) + b"]"
font_obj = 9  # after catalog(1) pages(2) and three page+content pairs (3..8)
procs = b" ".join(n.encode() + b" " + str(font_obj + 1 + i).encode() + b" 0 R"
                  for i, n in enumerate(names))
widths = b"1 " * 59  # FirstChar 32 .. LastChar 90
font = (b"<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] "
        b"/FontMatrix [1 0 0 1 0 0] /CharProcs << " + procs + b" >> "
        b"/Encoding << /Type /Encoding /Differences " + diffs + b" >> "
        b"/FirstChar 32 /LastChar 90 /Widths [" + widths + b"] "
        b"/Resources << >> /Name /Authored >>")
letter = corpus.stream(b"1 0 0 0 1 1 d1 0 0 m 1 0 l .5 1 l h f")
blank = corpus.stream(b"1 0 0 0 0 0 d1")

def page(parent_pages, content_obj, text):
    return (b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 96 72] "
            b"/Resources << /Font << /F1 " + str(font_obj).encode() + b" 0 R >> >> "
            b"/Contents " + str(content_obj).encode() + b" 0 R >>")

def line(text):
    return corpus.stream(b"BT /F1 6 Tf 1 0 0 1 4 60 Tm (" + text + b") Tj ET")

objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>",
    page(2, 4, b"ALPHA PAGE ONE"), line(b"ALPHA PAGE ONE"),
    page(2, 6, b"THE ZOOKEEPER SANG"), line(b"THE ZOOKEEPER SANG"),
    page(2, 8, b"OMEGA LAST PAGE"), line(b"OMEGA LAST PAGE"),
    font,
]
objs += [blank if n == "/Space" else letter for n in names]
open(os.path.join(rd_dir, "PAGES.PDF"), "wb").write(corpus.document(objs))

# The refusal leg's input: the pinned corpus negative the engine rejects
# with UnsupportedStroke.
neg = os.path.join("tests", "fixtures", "pdf", "acceptance", "negative-stroke.pdf")
if not os.path.exists(neg):
    sys.exit("missing corpus negative " + neg)
shutil.copy(neg, os.path.join(rd_dir, "STROKE.PDF"))

print("staged GOREADER.ELF (%d bytes), PAGES.PDF (%d bytes), STROKE.PDF"
      % (os.path.getsize(os.path.join(share, "GOREADER.ELF")),
         os.path.getsize(os.path.join(rd_dir, "PAGES.PDF"))))
PY

# --- run 01: the journey ---------------------------------------------------
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script.txt' \
    --input-chords 'pagedown,=,ctrl-f,Z,O,O,return' \
    --input-chords-after 'goreader: ready' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after "goreader: find 'ZOO' hit=1/1 page=2" \
    --snapshot-after "goreader: find 'ZOO' hit=1/1 page=2" \
    --script-expect 'rx-reader-journey-ok' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOREADER.ELF'
vgate_assert 01 serial-contains 'goreader: open id='
vgate_assert 01 serial-contains 'goreader: not-tab-aware'
vgate_assert 01 serial-contains 'goreader: loaded PAGES.PDF pages=3 128x96'
vgate_assert 01 serial-contains 'goreader: present'
vgate_assert 01 serial-contains 'goreader: ready'
# pagedown turned the page model, = stepped the zoom, the find hit landed.
vgate_assert 01 serial-contains 'goreader: page 2/3'
vgate_assert 01 serial-contains 'goreader: zoom z=150%'
vgate_assert 01 serial-contains 'goreader: find bar'
vgate_assert 01 serial-contains "goreader: find 'ZOO' hit=1/1 page=2"
vgate_assert 01 serial-contains 'rx-reader-journey-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The find hit is on screen: the accent band blends onto the ZOOKEEPER
# glyphs. Page 2 at 150% displays 192x144; centered in the 760px canvas it
# starts at canvas x=(760-192)/2=284, y=16. The band in page pixels is
# ~(37,8)-(109,18) -> displayed (55,12)-(164,27) -> canvas (339,28)-(448,43)
# -> scanout (+40,+24): x 379..488, y 52..67. The probe counts the blended
# accent over the white page (147,186,250) inside that box, tolerantly.
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want at least %d" % (len(raw), W * H * 4))

def px(x, y):
    off = (y * W + x) * 4
    return raw[off + 2], raw[off + 1], raw[off]  # BGRX -> rgb

# Window sits at (40,24); generous band around the expected hit region.
band = 0
for y in range(44, 90):
    for x in range(360, 520):
        r, g, b = px(x, y)
        if abs(r - 147) <= 24 and abs(g - 186) <= 24 and abs(b - 250) <= 24:
            band += 1
if band < 40:
    sys.exit("only %d accent-band px at the find hit - the ZOOKEEPER band "
             "did not paint" % band)
print("goreader journey: accent hit band px=%d" % band)
PY

# --- run 02: the named refusal ----------------------------------------------
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-02' \
    --script '$RUN_DIR/script-r.txt' \
    --script2 '$RUN_DIR/script2-r.txt' \
    --script2-after 'goreader: present' \
    --script2-delay 15 \
    --snapshot-after 'rx-reader-refuse-ok' \
    --script-expect 'rx-reader-refuse-ok' --timeout 240

vgate_assert 02 serial-contains 'exec: loaded GOREADER.ELF'
vgate_assert 02 serial-contains 'goreader: refuse UnsupportedStroke'
vgate_assert 02 serial-absent 'goreader: loaded '
vgate_assert 02 serial-contains 'goreader: present'
vgate_assert 02 serial-contains 'rx-reader-refuse-ok'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# The refusal names itself in the window: "REFUSED: UNSUPPORTEDSTROKE" is
# drawn at 2x in theme.Danger (0xef4444) centered in the canvas. The probe
# counts Danger-ink pixels inside the window (canvas 40..760 x, 24..584 y).
vgate_assert 02 snapshot 'snap-02-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want at least %d" % (len(raw), W * H * 4))

def px(x, y):
    off = (y * W + x) * 4
    return raw[off + 2], raw[off + 1], raw[off]

ink = 0
for y in range(60, 500):
    for x in range(60, 760):
        r, g, b = px(x, y)
        if r > 190 and g < 120 and b < 120:
            ink += 1
if ink < 40:
    sys.exit("only %d Danger-ink px - the refusal did not paint its name" % ink)
print("goreader refusal: Danger-ink px=%d" % ink)
PY
