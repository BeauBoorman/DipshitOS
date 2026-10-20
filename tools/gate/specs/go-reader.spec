# go-reader.spec -- M143a (issue #2792) + M143b (issue #2793) class-B gate:
# GOREADER.ELF, the Document mime's registered handler, opens a corpus-
# authored PDF on VZ, and the three open chains that route documents to it
# and images to GOVIEW all land end to end.
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
# Run 03 (M143b) is the K=3 acceptance journey: one boot walks all three
# open chains, and vgate_repeat 3 replays the whole spec so every leg is
# green three times.
#   1. WEB file-loads RDLPAGE.HTML, a pointer click on its .pdf link stages
#      the download (mime Document now downloads, never navigates), and the
#      completion plate's 'o' --input-key dispatches mime.Open ->
#      GOREADER.ELF, which renders page 1.
#   2. script2 execs GOFILES.ELF on /host/RD (DOC.PDF + PIC.SVG, sorted
#      DOC.PDF first); the --input-chords Return opens it -> GOREADER.ELF
#      renders page 1.
#   3. script3 execs GOFILES.ELF on /host/RDS (identical rows); the
#      --input-string 'j\n' moves the cursor to PIC.SVG and opens it ->
#      GOVIEW.ELF decodes the SVG.
#
# Focus choreography (the launch-then-focus handoff this spec relies on):
# every injection lands on whichever window opened LAST, and each script
# phase is anchored so the previous chain member's window already exists.
# script2 waits on leg 1's `goreader: ready`; script3 waits on leg 2's
# `goreader: loaded DOC.PDF` -- GOREADER#2's window is already open when
# GOFILES-B execs, so GOFILES-B's window takes focus and the typed Enter
# hits its listing, not the reader.
#
# HOST PREREQUISITES (fail the gate honestly when missing):
#   bash tools/go/build-goreader.sh             ->  .build/go/GOREADER.ELF
#   bash tools/go/build-files.sh                ->  .build/go/GOFILES.ELF
#   bash tools/go/build-goview.sh               ->  .build/go/GOVIEW.ELF
#   bash tools/go/build-web.sh browser WEB --gate -> .build/go/WEB-GATE.ELF
#
# exec-order: assert-proven -- runs 01/02 end on an rx- marker only the
# scripts print; run 03's three script phases are spent exec-ing the chain,
# so its terminal marker is the leg-3 app's own `gview: ready` (printed
# after the decoded frame paints) and every leg's decision/outcome/child
# marker set is asserted. A program that never ran cannot pass.

vgate_name go-reader "M143a (#2792) + M143b (#2793): GOREADER opens a corpus PDF - page nav, zoom, find-hit pixel, named refusal; K=3 WEB->GOREADER, GOFILES->GOREADER, GOFILES->GOVIEW open chains"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

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

# --- run 03 (M143b #2793): the K=3 open-chain journey ------------------------
# One boot per iteration walks all three open chains. The armed share is
# shared across iterations, so iteration n's download rewrites
# WEB-DL-RDRPDF.PDF through the same staged `~` -> rename path and adds a
# ledger row; the asserts below pin markers, not the row count.

vgate_file script-chain.txt <<'EOF'
settings set font_size medium
exec WEB.ELF /host/RDLPAGE.HTML
EOF

vgate_file script-chain-rd.txt <<'EOF'
exec GOFILES.ELF /host/RD
EOF

vgate_file script-chain-rds.txt <<'EOF'
exec GOFILES.ELF /host/RDS
EOF

vgate_setup_python <<'PY'
# Run 03's fixtures and handler ELFs (GOREADER.ELF itself is staged by the
# run-01 hook above). WEB rides its --gate build (WEB-GATE.ELF -> WEB.ELF),
# exactly as live-web stages it; GOFILES/GOVIEW are the shipping builds.
import os, shutil, sys
sys.path.insert(0, os.path.join(os.getcwd(), "tools", "pdf-proof"))
import corpus

rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")

for dst, src, build in (
    ("WEB.ELF", os.path.join(".build", "go", "WEB-GATE.ELF"),
     "bash tools/go/build-web.sh browser WEB --gate"),
    ("GOFILES.ELF", os.path.join(".build", "go", "GOFILES.ELF"),
     "bash tools/go/build-files.sh"),
    ("GOVIEW.ELF", os.path.join(".build", "go", "GOVIEW.ELF"),
     "bash tools/go/build-goview.sh"),
):
    if not os.path.exists(src):
        sys.exit(dst + " missing (expected " + src + ") - build it first: " + build)
    shutil.copy(src, os.path.join(share, dst))

# RDLPAGE.HTML mirrors the M126e gate-dl fixture: the first paragraph IS
# the link, so the proven 42,95 click lands on it at font_size medium
# (pinned in script-chain.txt). Its .pdf target is now a download, not a
# navigation: mime's Document family joins the download set in
# downloads.go's wantsDownload.
open(os.path.join(share, "RDLPAGE.HTML"), "w").write(
    "<html><body>\n"
    "<p><a href=\"RDRPDF.PDF\">download the document</a></p>\n"
    "<h1>Reader Download Fixture</h1>\n"
    "<p>This paragraph is long enough that the greedy word wrapper has to "
    "break it into at least two lines inside the browser content box.</p>\n"
    "<pre>preformatted block</pre>\n"
    "<hr>\n"
    "<p>The end.</p>\n"
    "</body></html>\n")

# A one-page 96x72pt Type3 text document — the same authored-font shape as
# PAGES.PDF above, one page so `goreader: loaded ... pages=1` reads plainly.
names = ["/Space"] + ["/" + chr(c) for c in range(ord('A'), ord('Z') + 1)]
diffs = b"[32 /Space 65 " + b" ".join(n.encode() for n in names[1:]) + b"]"
font_obj = 5  # after catalog(1) pages(2) page(3) content(4)
procs = b" ".join(n.encode() + b" " + str(font_obj + 1 + i).encode() + b" 0 R"
                  for i, n in enumerate(names))
font = (b"<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1 1] "
        b"/FontMatrix [1 0 0 1 0 0] /CharProcs << " + procs + b" >> "
        b"/Encoding << /Type /Encoding /Differences " + diffs + b" >> "
        b"/FirstChar 32 /LastChar 90 /Widths [" + b"1 " * 59 + b"] "
        b"/Resources << >> /Name /Authored >>")
letter = corpus.stream(b"1 0 0 0 1 1 d1 0 0 m 1 0 l .5 1 l h f")
blank = corpus.stream(b"1 0 0 0 0 0 d1")

def doc(text):
    return corpus.document([
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 96 72] "
        b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        corpus.stream(b"BT /F1 6 Tf 1 0 0 1 4 60 Tm (" + text + b") Tj ET"),
        font,
    ] + [blank if n == "/Space" else letter for n in names])

open(os.path.join(share, "RDRPDF.PDF"), "wb").write(doc(b"DOWNLOADED PAGE"))

# GOFILES's two directories carry IDENTICAL rows — DOC.PDF sorted first,
# PIC.SVG second — so the legacy dir-list scratch (a module-global snapshot
# that keeps its count across lists) returns correct rows for the second
# lister regardless of reuse. Leg 2's `return` opens DOC.PDF; leg 3's `j`
# moves to PIC.SVG.
svg = ('<svg width="48" height="32"><rect width="48" height="32" fill="red"/>'
       '</svg>\n').encode()
for name in ("RD", "RDS"):
    d = os.path.join(share, name)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "DOC.PDF"), "wb").write(doc(b"GOFILES DOCUMENT"))
    open(os.path.join(d, "PIC.SVG"), "wb").write(svg)

print("staged WEB.ELF + GOFILES.ELF + GOVIEW.ELF, RDLPAGE.HTML, "
      "RDRPDF.PDF (%dB), RD/{DOC.PDF,PIC.SVG}, RDS/{DOC.PDF,PIC.SVG}"
      % os.path.getsize(os.path.join(share, "RDRPDF.PDF")))
PY

# Leg 1 (WEB -> download -> plate 'o' -> GOREADER): pointer click after
# `web: ready` hits the link; `--input-key 31` is the plate's 'o' (keyDown
# over the cv-input queue, the live-web boot-46 delivery). Leg 2: script2
# execs GOFILES on RD once leg 1's reader is fully up (`goreader: ready` —
# its first occurrence is leg 1's); the chords Return opens DOC.PDF. Leg 3:
# script3 execs GOFILES on RDS only after `goreader: loaded DOC.PDF` —
# GOREADER#2's window is already open, so GOFILES-B's window takes focus
# and --input-string 'j\n' selects PIC.SVG (sorted second) into GOVIEW.
# The run's terminal marker is leg 3's own `gview: ready`.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-03' \
    --script '$RUN_DIR/script-chain.txt' \
    --pointer-virtio '42,95,c' --pointer-virtio-after 'web: ready' \
    --input-key 31 --input-key-after 'web: download done ' \
    --script2 '$RUN_DIR/script-chain-rd.txt' \
    --script2-after 'goreader: ready' \
    --input-chords 'return' \
    --input-chords-after 'gofiles: list /host/RD n=2' \
    --script3 '$RUN_DIR/script-chain-rds.txt' \
    --script3-after 'goreader: loaded DOC.PDF ' \
    --input-string $'j\n' \
    --input-string-after 'gofiles: list /host/RDS n=2' \
    --script-expect 'gview: ready' --timeout 300

# --- leg 1: WEB download -> completion plate -> GOREADER -------------------
vgate_assert 03 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 03 serial-contains 'exec: loaded WEB.ELF'
vgate_assert 03 serial-contains 'web: url /host/RDLPAGE.HTML'
vgate_assert 03 serial-contains 'web: ev kind=3'
vgate_assert 03 serial-contains 'web: download start RDRPDF.PDF bytes='
vgate_assert 03 serial-contains 'web: download /host/WEB-DL-RDRPDF.PDF '
vgate_assert 03 serial-contains 'web: download done RDRPDF.PDF type=document'
vgate_assert 03 serial-contains 'web: download open GOREADER.ELF /host/WEB-DL-RDRPDF.PDF'
vgate_assert 03 serial-contains 'web: download open launched pid='
vgate_assert 03 serial-contains 'goreader: loaded WEB-DL-RDRPDF.PDF pages=1 '
vgate_assert 03 serial-contains 'goreader: present'
vgate_assert 03 serial-contains 'goreader: ready'

# --- leg 2: GOFILES .pdf -> mime Document -> GOREADER -----------------------
vgate_assert 03 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 03 serial-contains 'gofiles: ready'
vgate_assert 03 serial-contains 'gofiles: list /host/RD n=2'
vgate_assert 03 serial-contains 'gofiles: entry DOC.PDF file'
vgate_assert 03 serial-contains 'gofiles: open file DOC.PDF type=document handler=GOREADER.ELF'
vgate_assert 03 serial-contains 'gofiles: open launched DOC.PDF handler=GOREADER.ELF pid='
vgate_assert 03 serial-contains 'goreader: loaded DOC.PDF pages=1 '

# --- leg 3: GOFILES .svg -> mime Image -> GOVIEW ----------------------------
vgate_assert 03 serial-contains 'gofiles: list /host/RDS n=2'
vgate_assert 03 serial-contains 'gofiles: entry PIC.SVG file'
vgate_assert 03 serial-contains 'gofiles: open file PIC.SVG type=image handler=GOVIEW.ELF'
vgate_assert 03 serial-contains 'gofiles: open launched PIC.SVG handler=GOVIEW.ELF pid='
vgate_assert 03 serial-contains 'gview: loaded PIC.SVG 48x32 '
vgate_assert 03 serial-contains 'gview: ready'

# --- the chain's refusals that must NOT happen ------------------------------
vgate_assert 03 serial-absent 'web: download failed'
vgate_assert 03 serial-absent 'web: download open refused'
vgate_assert 03 serial-absent 'web: download open exec-failed'
vgate_assert 03 serial-absent 'web: error'
vgate_assert 03 serial-absent 'gofiles: open refused'
vgate_assert 03 serial-absent 'gofiles: open launch refused'
vgate_assert 03 serial-absent 'gofiles: open cancelled'
vgate_assert 03 serial-absent 'gofiles: list error'
vgate_assert 03 serial-absent 'goreader: refuse'
vgate_assert 03 serial-absent 'gview: open err'
vgate_assert 03 serial-absent 'gview: read err'
vgate_assert 03 serial-absent 'gview: decode err'
vgate_assert 03 serial-absent 'gview: unsupported '
vgate_assert 03 serial-absent 'gview: too large'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# Chain order on the serial stream + the download's share-side evidence:
# the staged file matches the linked PDF byte-for-byte and the ledger row
# names it. The share persists across the K iterations, so the file must
# exist and match — the count of ledger rows is intentionally not pinned.
vgate_assert 03 python <<'PY'
import os
share = os.environ["VG_SHARE"]
ser = open(os.environ["VG_SER"], errors="replace").read()
order = [
    "web: download start RDRPDF.PDF",
    "web: download /host/WEB-DL-RDRPDF.PDF",
    "web: download done RDRPDF.PDF type=document",
    "web: download open GOREADER.ELF /host/WEB-DL-RDRPDF.PDF",
    "web: download open launched pid=",
    "goreader: loaded WEB-DL-RDRPDF.PDF pages=1",
    "gofiles: open file DOC.PDF type=document handler=GOREADER.ELF",
    "gofiles: open launched DOC.PDF handler=GOREADER.ELF",
    "goreader: loaded DOC.PDF pages=1",
    "gofiles: open file PIC.SVG type=image handler=GOVIEW.ELF",
    "gofiles: open launched PIC.SVG handler=GOVIEW.ELF",
    "gview: loaded PIC.SVG 48x32",
]
pos = 0
for marker in order:
    at = ser.find(marker, pos)
    assert at >= 0, "missing or out of order: " + marker
    pos = at + 1
dl = os.path.join(share, "WEB-DL-RDRPDF.PDF")
src = os.path.join(share, "RDRPDF.PDF")
assert os.path.exists(dl), "no downloaded file on the share"
got, want = open(dl, "rb").read(), open(src, "rb").read()
assert got == want, "download %d bytes != source %d bytes" % (len(got), len(want))
rows = [l for l in open(os.path.join(share, "WEB-DOWNLOADS.TXT"),
        errors="replace").read().splitlines() if l and not l.startswith("#")]
assert any("WEB-DL-RDRPDF.PDF" in r for r in rows), "no ledger row for the download"
print("go-reader 03 chain ok (web->goreader->gofiles->goreader->gofiles->goview "
      "ordering, share file %dB == source, ledger row)" % len(got))
PY
