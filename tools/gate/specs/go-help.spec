# go-help.spec -- M74c (issue #1646): GOHELP.ELF is a Bubble Tea TUI over
# the bound /dev/tty: one chord batch group-jumps through the GOSH catalog,
# browses the seeded /host/docs bundle, filters with `/`, and opens a full
# detail page. The screenshot asserts the detail page's exact truecolour
# accent (M73h) in the real scanout — not a host ANSI render.
#
# Shape: go-charmhello / go-fileman — direct exec on the kernel desktop
# (no `tabwm start` seat), native 512x384 window = the kernel grid's 64x23
# client (cols <= the grid's 80-col cap), chords over the real HID path,
# `dui` rect proof, and a screenshot barrier on the app's own post-detail
# marker.
#
# Marker discipline is load-bearing: the app flushes each frame's markers
# only AFTER painting it, so the screenshot at `gohelp: detail …` sees the
# detail frame, and `gohelp: settled after detail` (one yield later) is
# what script3 waits on before closing — the teardown can never race the
# capture.
#
# exec-order: assert-proven -- the run ends on `rx-gohelp-ok`, which only
# script3 prints, and script3 waits on the app's own settle marker; an app
# that never ran, never opened a detail, or never settled cannot pass.

vgate_name go-help "M74c #1646: the GOHELP.ELF Charm help browser group-jumps, filters, browses /host/docs and pixel-asserts a detail page over the bound tty"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOHELP.ELF
EOF

vgate_file script2.txt <<'EOF'
dui
EOF

vgate_file script3.txt <<'EOF'
dui close 2
echo rx-gohelp-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOHELP.ELF")
if not os.path.exists(src):
    sys.exit("GOHELP.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-help.sh")
shutil.copy(src, os.path.join(share, "GOHELP.ELF"))
docs = os.path.join(share, "docs")
os.makedirs(docs, exist_ok=True)
guide = os.path.join(docs, "GUIDE.TXT")
with open(guide, "w") as f:
    f.write("virelai help docs fixture\n")   # 26 bytes: pinned in serial assert
notes = os.path.join(docs, "NOTES.MD")
with open(notes, "w") as f:
    f.write("pinned help fixture two\n")     # 24 bytes
print("staged GOHELP.ELF into share (%d bytes), %s (%d bytes), %s (%d bytes)" %
      (os.path.getsize(os.path.join(share, "GOHELP.ELF")),
       guide, os.path.getsize(guide), notes, os.path.getsize(notes)))
PY

# The chord batch, in full (13 strokes at the cv-input transport's fixed
# 0.25 s): `l` hops to the files group head, `h` hops back to shell, then
# open the docs bundle, read its first page, back out to browse, arm `/`,
# type `ec` (pinned n=3: echo, secrets, exec), escape to clear, move onto
# echo with `j,j` (M83a's date sorts between clear and echo), and open
# the full detail — the LAST stroke, so the screenshot
# barrier and the dui script both fire against an idle app. Printable h/j/l
# avoid the currently unreliable multi-byte arrow input path.
vgate_run 01 -- \
    --screen '$RUN_DIR/help-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --input-chords 'l,h,d,return,backspace,backspace,/,e,c,escape,j,j,return' \
    --input-chords-after 'gohelp: ready' \
    --screenshot-after 'gohelp: detail echo usage=echo [ARG...]' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gohelp: detail echo usage=echo [ARG...]' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gohelp: settled after detail' \
    --script-expect 'rx-gohelp-ok' --timeout 240

# --- serial: the app ran, jumped, browsed, filtered, opened a detail -------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOHELP.ELF'
vgate_assert 01 serial-contains 'gohelp: open id='
vgate_assert 01 serial-contains 'gohelp: attached'
vgate_assert 01 serial-contains 'gohelp: painted'
vgate_assert 01 serial-contains 'gohelp: ready'
vgate_assert 01 serial-contains 'gohelp: present'

# The catalog came from shlib.HelpRows — single-sourced from GOSH's
# helpCatalog (n=51 is the drift tripwire; model_test.go pins the same
# number on the host), and the seeded docs bundle is visible.
vgate_assert 01 serial-contains 'gohelp: catalog n=51'
vgate_assert 01 serial-contains 'gohelp: docs n=2'

# The window itself: native rect on the kernel desktop (dui from script2,
# fired at the detail barrier, so it describes the live window) — the
# charmhello/fileman dui row shape.
vgate_assert 01 serial-contains 'dui[4]: user user rect=32,32,512,384'

# Group navigation: `l` lands on the files head (ASCII sorts `.` before the
# letters — observed), `h` hops back to the shell head.
vgate_assert 01 serial-contains 'gohelp: focus . group=files'
vgate_assert 01 serial-contains 'gohelp: focus clear group=shell'
vgate_assert 01 serial-contains 'gohelp: key l'
vgate_assert 01 serial-contains 'gohelp: key h'

# Docs section: the seeded bundle's first page read whole (26 bytes).
vgate_assert 01 serial-contains 'gohelp: docs open'
vgate_assert 01 serial-contains 'gohelp: docfocus GUIDE.TXT'
vgate_assert 01 serial-contains 'gohelp: doc GUIDE.TXT bytes=26'

# Back to browse, then `/`-to-filter: `ec` matches exactly three rows
# (echo, secrets, exec — pinned in model_test.go), escape clears to the
# full catalog.
vgate_assert 01 serial-contains 'gohelp: browse'
vgate_assert 01 serial-contains 'gohelp: filter on'
vgate_assert 01 serial-contains 'gohelp: filter ec n=3'
vgate_assert 01 serial-contains 'gohelp: filter cleared n=51'

# Key labels line up with the chord table verbatim.
vgate_assert 01 serial-contains 'gohelp: key d'
vgate_assert 01 serial-contains 'gohelp: key /'
vgate_assert 01 serial-contains 'gohelp: key escape'

# The detail page the screenshot captures: name, then the usage line the
# barrier sequences on.
vgate_assert 01 serial-contains 'gohelp: focus echo group=shell'
vgate_assert 01 serial-contains 'gohelp: detail echo usage=echo [ARG...]'
vgate_assert 01 serial-contains 'gohelp: key j'
vgate_assert 01 serial-contains 'gohelp: settled after detail'

# Clean teardown through the window-close path.
vgate_assert 01 serial-contains 'gohelp: close'
vgate_assert 01 serial-contains 'gohelp OK'
vgate_assert 01 serial-contains 'rx-gohelp-ok'

# --- serial: the refusals that must NOT happen ------------------------------
vgate_assert 01 serial-absent 'gohelp: no /dev/tty'
vgate_assert 01 serial-absent 'gohelp: attach failed'
vgate_assert 01 serial-absent 'gohelp: doc error'
# M73i selection precedence: with ?1000/?1006 enabled, a plain pointer
# never falls through to kernel selection.
vgate_assert 01 serial-absent 'dui: term sel begin'
vgate_assert 01 serial-absent 'dui: term sel end'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- scanout: the detail page's exact accent in the REAL framebuffer -------
# The barrier is the detail marker itself (printed AFTER its frame
# painted). At that frame the full-page detail shows echo's name in the
# header and its usage/blurb in the body — painted by the kernel's
# truecolour path from `38;2;255;199;92`.
#
# Geometry (observed, same 2x Retina capture as go-fileman): the PNG is
# 2560x1440 while `dui`'s rect is in LOGICAL points, so the native 512x384
# window at (32,32) occupies x=64..1088, y=64..832 and the client starts at
# y=96. The 8x16 terminal cell is 16x32 capture pixels; detail rows 0..3
# (header, usage, blank, blurb) occupy y=96..224. This band excludes the
# amber STATUS row (row 20), so only detail text can count.
#
# ScreenCaptureKit's compositing can shift glyph pixels more than 20/channel
# from the ANSI RGB. Across observed captures, +/-36 finds 399..1711 pixels
# in the detail band. The 300-pixel floor exceeds the largest single detail
# line in the lower-count capture (274 pixels), requiring multiple detail
# lines while excluding other panes and status rows.
vgate_assert 01 snapshot 'help-screen-after' <<'PY'
import struct, sys, zlib

d = open(sys.argv[1], "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG scanout"
pos = 8
idat = b""
w = h = ct = 0
while pos < len(d):
    n, typ = struct.unpack(">I4s", d[pos:pos + 8])
    chunk = d[pos + 8:pos + 8 + n]
    if typ == b"IHDR":
        w, h, depth, ct = struct.unpack(">IIBB", chunk[:10])
        assert depth == 8, "unexpected PNG depth"
    elif typ == b"IDAT":
        idat += chunk
    pos += 12 + n
assert (w, h) == (2560, 1440), "wanted 2560x1440 scanout, got %dx%d" % (w, h)
bpp = 4 if ct == 6 else 3
raw = zlib.decompress(idat)
stride = w * bpp
out = bytearray()
prev = bytearray(stride)
i = 0
for _ in range(h):
    filt = raw[i]
    i += 1
    row = bytearray(raw[i:i + stride])
    i += stride
    if filt == 1:
        for x in range(bpp, stride):
            row[x] = (row[x] + row[x - bpp]) & 0xff
    elif filt == 2:
        for x in range(stride):
            row[x] = (row[x] + prev[x]) & 0xff
    elif filt == 3:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            row[x] = (row[x] + ((left + prev[x]) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up_left = prev[x - bpp] if x >= bpp else 0
            up = prev[x]
            p = left + up - up_left
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
            pred = (left if pa <= pb and pa <= pc else up if pb <= pc else up_left)
            row[x] = (row[x] + pred) & 0xff
    out += row
    prev = row

# The detail TEXT band only: window client x=64..1088, rows 0..3 at
# 32 capture pixels each (header, usage, blank, blurb) — y=96..224.
accent = 0
for y in range(96, 224):
    for x in range(64, 1088):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k + 1], out[k + 2]
        if abs(r - 255) <= 36 and abs(g - 199) <= 36 and abs(b - 92) <= 36:
            accent += 1
print("gohelp scanout: detail-accent=%d" % accent)
assert accent >= 300, "detail accent (255,199,92, +/-36) absent from the detail text band"
PY
