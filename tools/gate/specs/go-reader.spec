# go-reader.spec -- M143a (issue #2792) + M143b (issue #2793) + M153c
# (issue #2923) + M153d (issue #2924) class-B gate:
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
# Run 04 (M153c) is the v2 leg: one boot execs GOREADER on PAGES.PDF, 'end'
# lands page 3 (absolute — immune to a carried-over position row), 'b'
# bookmarks it, 's'+return saves a byte copy through the picker (the app's
# seeded PAGES-COPY.PDF name), and 'q' quits, which flush-writes
# /host/GOREADER.POS. script2 re-execs the same document: the row's
# page/zoom/bookmarks restore and the 'goreader: pos page=3 bm=3' marker is
# the reopen's proof. The python assert compares the copy's SHA-256 to the
# source's AND removes both GOREADER.POS and the copy, because the armed
# share persists across the vgate_repeat boots — position memory must not
# bleed into the next iteration's run 01.
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
# Run 05 (M153d) closes the M153 loop: the file the OS writes is a file
# the OS and the host both read. One boot on a RUN-SCOPED share
# (--cvc-file: run 04 deletes the armed share's GOREADER.POS every
# iteration, so this leg cannot live there):
#   phase 1: GOEDIT opens the staged ACCSEED.TXT, the M153b picker lands
#     a .pdf name -> `edit: export pdf /host/EXPORT.PDF pages=3`, then
#     `dui close 2` ends the author side.
#   phase 2: GOREADER opens EXPORT.PDF. The run's single --input-chords
#     burst belongs to the picker (only it can spell ctrl-shift-s), so
#     page 2 is reached through the app's own position memory: the share
#     seeds a GOREADER.POS row keyed to the export's (path,size,sha8) —
#     computed host-side through the same virelai/pdfwrite, whose only
#     nondeterminism is the tail CreationDate, outside the 4096-byte
#     head the row hashes. `pos page=2` is the landing; 'b'+'q' over
#     --input-string are the bookmark and the pos-writing close; the
#     `bookmark on page=2` anchors the scanout probe — post-repaint,
#     the window idles until 'q' lands, so the composite is settled.
#   phase 3: the reopen — `pos page=2 z=100 bm=2` proves the page and
#     the bookmark both survived the close.
# Host side, the built cgrender (ADR 0040 outside reference) renders
# EXPORT.PDF page 2 at 96 dpi and the python block compares it with the
# scanout crop inside the live-web-57 tolerance, verifies the PDF's
# structure, then restores the seeded row so the next iteration
# replays identically.
#
# HOST PREREQUISITES (fail the gate honestly when missing):
#   bash tools/go/build-goreader.sh             ->  .build/go/GOREADER.ELF
#   bash tools/go/build-goedit.sh               ->  .build/go/GOEDIT.ELF
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

# --- run 04 (M153c #2923): bookmarks, position memory, save a copy --------
# script files
vgate_file script-v2.txt <<'EOF'
exec GOREADER.ELF /host/READER/PAGES.PDF
EOF

vgate_file script-v2-reopen.txt <<'EOF'
exec GOREADER.ELF /host/READER/PAGES.PDF
EOF

vgate_file script2-v2.txt <<'EOF'
echo rx-reader-v2-ok
EOF

# One chord batch drives the whole first lifetime: end -> page 3 (absolute
# landing, so a position row left by run 01 cannot skew it), b -> bookmark,
# s -> picker with the seeded PAGES-COPY.PDF name, return -> the picker's
# save verb, q -> quit (the close-write publishes GOREADER.POS). script2
# re-execs the same document once the quit marker lands; its 'pos page=3'
# restore marker fires script3's rx- end marker.
vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --via-virtio \
    --script '$RUN_DIR/script-v2.txt' \
    --input-chords 'end,b,s,return,q' \
    --input-chords-after 'goreader: ready' \
    --script2 '$RUN_DIR/script-v2-reopen.txt' \
    --script2-after 'goreader: quit' \
    --script3 '$RUN_DIR/script2-v2.txt' \
    --script3-after 'goreader: pos page=3' \
    --script-expect 'rx-reader-v2-ok' --timeout 240

vgate_assert 04 serial-contains 'exec: loaded GOREADER.ELF'
vgate_assert 04 serial-contains 'goreader: loaded PAGES.PDF pages=3'
vgate_assert 04 serial-contains 'goreader: page 3/3'
vgate_assert 04 serial-contains 'goreader: bookmark on page=3 n=1'
vgate_assert 04 serial-contains 'goreader: save pick'
vgate_assert 04 serial-contains 'goreader: save /host/READER/PAGES-COPY.PDF bytes='
vgate_assert 04 serial-contains 'goreader: quit'
vgate_assert 04 serial-contains 'goreader: pos saved n='
# The reopen: position + the bookmark list ride back out of GOREADER.POS.
vgate_assert 04 serial-contains 'goreader: pos page=3'
vgate_assert 04 serial-contains ' bm=3'
vgate_assert 04 serial-contains 'rx-reader-v2-ok'
vgate_assert 04 serial-absent 'goreader: refuse'
vgate_assert 04 serial-absent 'goreader: save rc='
vgate_assert 04 serial-absent 'goreader: pos rc='
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

# Share-side proof, then the reset that keeps vgate_repeat deterministic:
# the copy is byte-identical (SHA-256) and the POS row names page 2
# (0-based) with bookmark [2] under the document's path+size+sha8 key; then
# both artifacts are removed so iteration n+1's run 01 opens PAGES.PDF cold.
vgate_assert 04 python <<'PY'
import hashlib, os
share = os.environ["VG_SHARE"]
src = os.path.join(share, "READER", "PAGES.PDF")
copy = os.path.join(share, "READER", "PAGES-COPY.PDF")
pos = os.path.join(share, "GOREADER.POS")
assert os.path.exists(copy), "save-a-copy never landed"
hsrc = hashlib.sha256(open(src, "rb").read()).hexdigest()
assert hashlib.sha256(open(copy, "rb").read()).hexdigest() == hsrc, \
    "copy bytes differ from source"
rows = [l for l in open(pos, errors="replace").read().splitlines()
        if l and not l.startswith("#")]
assert rows, "GOREADER.POS has no rows"
hexpath = "/host/READER/PAGES.PDF".encode().hex()
sha8 = hashlib.sha256(open(src, "rb").read(4096)).hexdigest()[:16]
match = [r for r in rows if r.endswith("\t" + hexpath)]
assert match, "no GOREADER.POS row for PAGES.PDF"
f = match[0].split("\t")
assert len(f) == 7, "row shape %r" % match[0]
assert f[0] == str(os.path.getsize(src)), "size key %r" % f[0]
assert f[1] == sha8, "sha8 key %r want %s" % (f[1], sha8)
assert f[2] == "2", "stored page %r (want 0-based 2)" % f[2]
assert "2" in f[5].split(","), "bookmark missing from %r" % f[5]
os.unlink(pos)
os.unlink(copy)
print("goreader v2: copy sha256=%s identical; pos row page=2 bm=2; "
      "share reset for next iteration" % hsrc[:16])
PY

# --- run 05 (M153d #2924): author -> export -> read -> host verify ----------
# Script files: one exec per phase. script2's `dui close 2` releases
# GOEDIT's window (first user window on a bare boot) before GOREADER#1
# execs — the seat envelope never sees more than two user Go runtimes.
vgate_file script-05.txt <<'EOF'
exec GOEDIT.ELF /host/ACCSEED.TXT
EOF

vgate_file script2-05.txt <<'EOF'
dui close 2
exec GOREADER.ELF /host/EXPORT.PDF
EOF

vgate_file script3-05.txt <<'EOF'
exec GOREADER.ELF /host/EXPORT.PDF
EOF

# The run-scoped share and the seeded position row. ACCSEED.TXT is
# 161 short ASCII lines: the export's 80-row grid paginates that
# into three pages with one text row on page 1, two on page 2, and
# a footer row on every page — the shown-glyph total stays inside
# both pdfwrite's normalized-command budget and the reader engine's
# per-page edge bound (a third short line on page 2 trips
# SegmentLimit); the CreationDate sits past byte 4096 so the pos
# row's head hash keys cleanly.
vgate_setup_python <<'PY'
import hashlib, os, shutil, subprocess, sys, tempfile

rd = os.environ["RUN_DIR"]
acc = os.path.join(rd, "accept-share")
os.makedirs(acc, exist_ok=True)

for name, build in (("GOEDIT.ELF", "bash tools/go/build-goedit.sh"),
                    ("GOREADER.ELF", "bash tools/go/build-goreader.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + build)
    shutil.copy(src, os.path.join(acc, name))

lines = ["M153D ACCEPTANCE ROW"] + [""] * 79 + [
    "PAGE TWO ROW ONE", "PAGE TWO ROW TWO",
] + [""] * 79
assert len(lines) == 161
assert all(len(l) <= 90 for l in lines)
seed = ("\n".join(lines) + "\n").encode("ascii")
with open(os.path.join(acc, "ACCSEED.TXT"), "wb") as fh:
    fh.write(seed)

# The seeded row needs the export's (path,size,sha8-of-head) key.
# pdfwrite's only nondeterminism is CreationDate, which lives in the
# tail Info object — outside the 4096-byte head the row hashes — so the
# shipped library run host-side on the same rows and layout yields the
# exact key. The helper mirrors user/go/edit/export.go's wrap/footer
# constants under this seed's contract (tab-free ASCII, <=90 columns).
KEYGEN = r'''
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"virelai/pdfwrite"
)

const (
	exportCols      = 90
	exportPageRows  = 80
	exportLeft      = 48
	exportTop       = 48
	exportLead      = 12
	exportFooterRow = 81
)

func exportFooter(page, pages int) string {
	s := strconv.Itoa(page) + " / " + strconv.Itoa(pages)
	pad := (exportCols - len(s)) / 2
	if pad < 0 {
		pad = 0
	}
	return strings.Repeat(" ", pad) + s
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: m153dkey SEED.txt > out.pdf")
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	// exportWrapAll, under the gate's seed contract: tab-free ASCII
	// lines inside the column bound wrap 1:1 into rows; the buffer's
	// trailing newline still emits its blank row.
	var rows []string
	for off := 0; ; {
		end := off
		for end < len(data) && data[end] != '\n' {
			end++
		}
		line := string(data[off:end])
		if len(line) > exportCols {
			fmt.Fprintln(os.Stderr, "seed line exceeds the export column bound")
			os.Exit(1)
		}
		for i := 0; i < len(line); i++ {
			if line[i] < 0x20 || line[i] > 0x7e {
				fmt.Fprintln(os.Stderr, "seed byte outside the ASCII draw domain")
				os.Exit(1)
			}
		}
		rows = append(rows, line)
		if end == len(data) {
			break
		}
		off = end + 1
	}
	pages := (len(rows) + exportPageRows - 1) / exportPageRows
	d := pdfwrite.New(pdfwrite.Meta{Title: "EXPORT.PDF", Producer: "GOEDIT.ELF",
		Now: func() time.Time { return time.Unix(1700000000, 0).UTC() }})
	for p := 0; p < pages; p++ {
		body := rows[p*exportPageRows:]
		if len(body) > exportPageRows {
			body = body[:exportPageRows]
		}
		lines := make([]string, 0, exportFooterRow+1)
		lines = append(lines, body...)
		for len(lines) < exportFooterRow {
			lines = append(lines, "")
		}
		lines = append(lines, exportFooter(p+1, pages))
		if _, err := d.AddTextPage(lines, pdfwrite.TextOptions{
			Scale: 1, Left: exportLeft, Top: exportTop, LineAdvance: exportLead,
		}); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	out, err := d.Bytes()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Stdout.Write(out)
}
'''

fork = os.environ.get("GO_FORK_DIR") or os.path.join(
    os.path.dirname(os.getcwd()), "go-virelai")
gobin = os.path.join(fork, "bin", "go")
if not os.path.exists(gobin):
    sys.exit("go toolchain missing at " + gobin +
             " - provision it: bash tools/go/apply.sh && just go-toolchain")
gp = tempfile.mkdtemp(prefix="m153d-keygen.")
os.makedirs(os.path.join(gp, "src", "m153dkey"))
os.symlink(os.path.join(os.getcwd(), "user", "go"),
           os.path.join(gp, "src", "virelai"))
with open(os.path.join(gp, "src", "m153dkey", "main.go"), "w") as fh:
    fh.write(KEYGEN)
env = dict(os.environ)
env.update(GOROOT=fork,
           PATH=os.path.join(fork, "bin") + os.pathsep + env["PATH"],
           GOTOOLCHAIN="local", GO111MODULE="off", GOFLAGS="",
           GOPATH=gp, CGO_ENABLED="0")
r = subprocess.run([gobin, "run", "m153dkey",
                    os.path.join(acc, "ACCSEED.TXT")],
                   env=env, capture_output=True)
if r.returncode != 0:
    sys.exit("keygen failed: " + r.stderr.decode("utf-8", "replace")[:400])
pdf = r.stdout
if len(pdf) <= 4400:
    sys.exit("keygen export is %d bytes; the row's head hash needs the "
             "CreationDate past byte 4096 (want > 4400)" % len(pdf))
sha8 = hashlib.sha256(pdf[:4096]).hexdigest()[:16]
hexpath = "/host/EXPORT.PDF".encode().hex()
with open(os.path.join(acc, "GOREADER.POS"), "w") as fh:
    fh.write("# virelai-goreader-pos v1 (size<TAB>sha8<TAB>page<TAB>zoom"
             "<TAB>fit<TAB>bookmarks<TAB>hex(path); most-recent first)\n")
    fh.write("%d\t%s\t1\t100\t0\t\t%s\n" % (len(pdf), sha8, hexpath))
print("accept-share staged: GOEDIT.ELF + GOREADER.ELF, ACCSEED.TXT "
      "(%d rows), pos row keyed size=%d sha8=%s (export %dB)"
      % (len(lines) + 1, len(pdf), sha8, len(pdf)))
PY

# The single --input-chords burst drives the picker (ctrl-shift-s is
# unreachable any other way); GOREADER#1's landing is the seeded pos
# row, its bookmark + quit are --input-string's 'b'/'q', and the
# snapshot anchors on `bookmark on page=2` — the post-repaint marker
# leaves the window up while the probe composites. script3's exec is the reopen: `pos page=2 z=100 bm=2`
# is both the proof and the terminal marker (the 1.5 s tail still
# catches the second lifetime's present/ready/pos-saved lines).
vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-05' \
    --cvc-file '$RUN_DIR/accept-share' \
    --script '$RUN_DIR/script-05.txt' \
    --input-chords 'ctrl-shift-s,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,E,X,P,O,R,T,.,P,D,F,return' \
    --input-chords-after 'goedit: present' \
    --script2 '$RUN_DIR/script2-05.txt' \
    --script2-after 'edit: export pdf /host/EXPORT.PDF' \
    --snapshot-after 'goreader: bookmark on page=2 n=1' \
    --input-string 'bq' --input-string-after 'goreader: ready' \
    --script3 '$RUN_DIR/script3-05.txt' \
    --script3-after 'goreader: quit' \
    --script-expect 'goreader: pos page=2 z=100 bm=2' --timeout 300

# The author side.
vgate_assert 05 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 05 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 05 serial-contains 'goedit: open id=2'
vgate_assert 05 serial-contains 'goedit: read /host/ACCSEED.TXT n='
vgate_assert 05 serial-contains 'goedit: present'
vgate_assert 05 serial-contains 'goedit: pick save /host/EXPORT.PDF'
vgate_assert 05 serial-contains 'edit: export pdf /host/EXPORT.PDF pages=3 bytes='
vgate_assert 05 serial-contains 'goedit: close'
vgate_assert 05 serial-contains 'goedit OK'
# The export moved neither the session path nor the dirty flag: the
# picker name is never a saved document.
vgate_assert 05 serial-absent 'goedit: saved /host/EXPORT.PDF'
vgate_assert 05 serial-absent 'edit: export refused'

# The read side: open, seeded landing, bookmark, pos-writing close.
vgate_assert 05 serial-contains 'exec: loaded GOREADER.ELF'
vgate_assert 05 serial-contains 'goreader: open id='
vgate_assert 05 serial-contains 'goreader: not-tab-aware'
vgate_assert 05 serial-contains 'goreader: loaded EXPORT.PDF pages=3 816x1056 bytes='
vgate_assert 05 serial-contains 'goreader: pos page=2 z=100 bm=-'
vgate_assert 05 serial-contains 'goreader: page 2/3'
vgate_assert 05 serial-contains 'goreader: bookmark on page=2 n=1'
vgate_assert 05 serial-contains 'goreader: quit'
vgate_assert 05 serial-contains 'goreader: pos saved n=1'
# The reopen: the row's page and bookmark come back — the OS reads the
# position memory the OS wrote, on the file the OS exported.
vgate_assert 05 serial-contains 'goreader: pos page=2 z=100 bm=2'
vgate_assert 05 serial-count 'goreader: page 2/3' 2
vgate_assert 05 serial-count 'goreader: ready' 2
vgate_assert 05 serial-absent 'goreader: refuse'
vgate_assert 05 serial-absent 'goreader: pos rc='
vgate_assert 05 serial-absent 'goreader: read err'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'

# The scanout probe: page 2's top-left 760x531 sits 1:1 at scanout
# (40,40) — the page is 816x1056 at the restored 100% inside the 760x531
# viewport, so the crop carries white page fill plus the three text
# rows' glyph ink.
vgate_assert 05 snapshot 'snap-05-*.raw' <<'PY'
import sys
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
assert len(raw) == W * H * 4, "scanout size %d" % len(raw)
def px(x, y):
    k = (y * W + x) * 4
    return raw[k + 2], raw[k + 1], raw[k]
white = ink = 0
for y in range(40, 571):
    for x in range(40, 800):
        r, g, b = px(x, y)
        if r > 235 and g > 235 and b > 235:
            white += 1
        elif r < 60 and g < 60 and b < 60:
            ink += 1
assert white > 300000, "page-2 fill did not reach the scanout (%d px)" % white
assert ink > 500, "no glyph ink on page 2 (%d px)" % ink
print("go-reader 05: page-2 crop on the scanout (white=%d ink=%d)" % (white, ink))
PY

# The file the OS wrote is a file the host reads: structure, the pos
# row it earned, and the cgrender pixel compare against the scanout
# crop — then the seeded row is restored for the next iteration.
vgate_assert 05 python <<'PY'
import glob, hashlib, os, re, struct, subprocess, sys
rd = os.environ["RUN_DIR"]
acc = os.path.join(rd, "accept-share")
path = os.path.join(acc, "EXPORT.PDF")
if not os.path.exists(path):
    sys.exit("EXPORT.PDF never landed on the run share")
data = open(path, "rb").read()
if not data.startswith(b"%PDF-1."):
    sys.exit("bad header: %r" % data[:16])
m = re.search(rb"startxref\s*(\d+)\s*%%EOF", data)
if not m:
    sys.exit("no startxref")
xref = int(m[1])
if data[xref:xref + 4] != b"xref":
    sys.exit("startxref does not land on xref (%d)" % xref)
sec = data[xref:].split(b"\n", 2)
n = int(sec[1].split()[1])
lines = sec[2].split(b"\n")[:n]
for i, line in enumerate(lines):
    off, gen, flag = line.split()
    if flag == b"f":
        continue
    off = int(off)
    want = ("%d 0 obj" % i).encode()
    if data[off:off + len(want)] != want:
        sys.exit("xref offset %d -> %r, want %r" % (i, data[off:off + 16], want))
m = re.search(rb"/Type /Pages[^>]*?/Count (\d+)", data)
if not m or int(m[1]) != 3:
    sys.exit("page count %r" % (m[1] if m else None))
if b"/Producer (GOEDIT.ELF)" not in data:
    sys.exit("Info producer missing")

# The position row after close+reopen names the same document, page 2
# (0-based 1) and the bookmark — then the seeded shape goes back so
# iteration n+1 replays identically.
pos = os.path.join(acc, "GOREADER.POS")
rows = [l for l in open(pos, errors="replace").read().splitlines()
        if l and not l.startswith("#")]
if not rows:
    sys.exit("GOREADER.POS has no rows")
hexpath = "/host/EXPORT.PDF".encode().hex()
match = [r for r in rows if r.endswith("\t" + hexpath)]
if not match:
    sys.exit("no GOREADER.POS row for EXPORT.PDF")
f = match[0].split("\t")
if len(f) != 7:
    sys.exit("row shape %r" % match[0])
sha8 = hashlib.sha256(data[:4096]).hexdigest()[:16]
if f[0] != str(len(data)):
    sys.exit("size key %r want %d" % (f[0], len(data)))
if f[1] != sha8:
    sys.exit("sha8 key %r want %s" % (f[1], sha8))
if f[2] != "1":
    sys.exit("stored page %r (want 0-based 1)" % f[2])
if "1" not in f[5].split(","):
    sys.exit("bookmark missing from %r" % f[5])
schema = open(pos, errors="replace").read().splitlines()[0]
with open(pos, "w") as fh:
    fh.write(schema + "\n")
    fh.write("%d\t%s\t1\t100\t0\t\t%s\n" % (len(data), sha8, hexpath))

# Iteration n's boot also persists the WND server's window table:
# WINDOWS.SAV left on the share restores a phantom window that takes id 2
# before GOEDIT execs (its `open id=3` then ducks the scripted `dui
# close 2`), so the reset removes it along with the pos row restore.
wmsav = os.path.join(acc, "WINDOWS.SAV")
if os.path.exists(wmsav):
    os.unlink(wmsav)

# The outside reference: CoreGraphics at 96 dpi renders EXPORT.PDF
# page 2; the guest's frame is its top-left 760x531 at 1:1 on the
# scanout at (40,40). Type3 glyph rects land on integer device pixels
# in both renderers — edge AA is the only slack, so the live-web-57
# bounds hold (per-channel TOL + mismatch fraction + mean).
binary = ".build/pdf-proof/cgrender"
if not os.path.exists(binary):
    os.makedirs(".build/pdf-proof", exist_ok=True)
    subprocess.check_call(["/usr/bin/swiftc", "-O", "-module-cache-path",
        ".build/pdf-proof/module-cache", "tools/pdf-proof/cgrender.swift",
        "-o", binary])
out = os.path.join(rd, "export-p2.bgra")
env = {k: v for k, v in os.environ.items() if not k.startswith("DYLD_")}
env["CG_PDF_VERBOSE"] = "1"
r = subprocess.run([os.path.abspath(binary), path, out, "2"], env=env,
                   capture_output=True, text=True, timeout=60)
assert r.returncode == 0, "cgrender failed: " + r.stderr[:400]
open(os.path.join(rd, "export-p2.cglog"), "w").write(r.stderr)
assert "caught exception" not in r.stderr, "oracle diagnostics: " + r.stderr[:400]
cg = open(out, "rb").read()
w, h, stride = struct.unpack_from("<III", cg, 4)
assert (w, h, stride) == (816, 1056, 816), "cgrender geometry %dx%d" % (w, h)
pix = cg[16:]
snaps = sorted(glob.glob(os.path.join(rd, "snap-05-*.raw")))
assert snaps, "no scanout capture"
raw = open(max(snaps, key=os.path.getmtime), "rb").read()
assert len(raw) == 1280 * 720 * 4, "scanout size %d" % len(raw)
def scan(x, y):
    k = (y * 1280 + x) * 4
    return raw[k + 2], raw[k + 1], raw[k]
def ref(x, y):
    k = (y * stride + x) * 4
    return pix[k + 2], pix[k + 1], pix[k]
mism = total = 0
sumdiff = 0
TOL = 48
for cy in range(531):
    for cx in range(760):
        a = scan(40 + cx, 40 + cy)
        b = ref(cx, cy)
        d = max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))
        sumdiff += abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])
        total += 1
        if d > TOL:
            mism += 1
frac = mism / total
mean = sumdiff / (3 * total)
assert frac <= 0.08 and mean <= 24, \
    "cgrender vs scanout: mism=%.4f mean=%.2f" % (frac, mean)
print("go-reader 05: EXPORT.PDF structure ok (%d bytes, %d xref objs, "
      "pages=3); pos row page=1 bm=1 restored to seed; cgrender page 2 "
      "vs scanout crop (mismatch %.4f%%, mean %.2f/255, tol %d)"
      % (len(data), n, frac * 100, mean, TOL))
PY
