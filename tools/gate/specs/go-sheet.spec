# go-sheet.spec -- M142a (issue #2789) class-B gate: the Go spreadsheet opens
# under the bare shim, takes values and formulas through injected keystrokes,
# recalculates dependents on edit, and refuses a cycle by name (#CYCLE).
#
# user/go/gosheet is a tabapp client: init -> declare (refused under the shim,
# so the window keeps its declared 672x420 rect at (64,48) and the kernel blits
# it 1:1) -> present -> accept keystrokes into the grid + edit line. The grid
# is the M137b (#2772) virtualized table; the cell text is the kit's 8x8
# bitmap face, so the snapshot probe below DECODES cell text back from the
# BGRX scanout (glyph rows matched bit-exact against Font8x8) instead of
# trusting a serial marker.
#
# Chord vocabulary note: the runner's --input-chords table cannot spell
# '(' or ')' (go-calc.spec documents the same bound), so the grammar accepts
# '[' and ']' as paren aliases — '=sum[a1:a2]' is the gate spelling.
#
#   run 01  recalc leg: A1=2, A2=3, B1==sum[a1:a2] -> 5, re-edit A1 to 10,
#           the probe decodes B1 = '13' (and A1='10', A2='3') from pixels.
#   run 02  error leg: A1==b1 waits on an empty cell (0), B1==a1 closes the
#           loop -> A1,B1 both #CYCLE; C1==1/0 -> #DIV/0; D1==zz1 -> #REF;
#           E1==foo -> #PARSE. The probe decodes all four error codes.
#
# M142b (issue #2790) legs — CSV import/export through the FilePicker, the
# text/csv clipboard lane, and save_state/restore_state:
#   run 03  paste leg: `clip '7,"e,f",9'` seeds the kernel buffer, ctrl-v
#           fills A1:C1 from the cursor, ctrl-shift-m + right marks A1:B1,
#           ctrl-c stores `7,"e,f"` as text/csv — `clip` reads the bytes
#           back — and the probe decodes all three pasted cells on pixels.
#   run 04  picker-open leg: ctrl-o raises the FilePicker, SMALL.CSV (one
#           quoted-comma field) imports wholesale, the probe decodes it.
#   run 05  refusal+export leg: argv imports BIG.CSV (32x8, ~1 KiB), ctrl-a
#           selects the used box, ctrl-c refuses `clip-too-large` (the
#           card's named reason), ctrl-s exports through the picker and a
#           host-side byte-compare proves OUT.CSV == BIG.CSV.
#   run 06  seat state leg (GOTABWM): cells typed, end+pagedown scroll the
#           view, ctrl-shift-w closes (seat collects the blob), ctrl-shift-t
#           re-execs — `gosheet: state restored` reports cells=2 and the
#           saved cursor+scroll.
#
# The clipboard legs need CAP_CLIPBOARD: `exec -u0` is the capable path —
# an exec'd app under the tabbed seat runs uid_user without caps (the
# go-edit.spec run-06 convention). The FilePicker and save_state need no
# manifest grant.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gosheet.sh   ->  .build/go/GOSHEET.ELF
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF  (run 06)
#
# exec-order: assert-proven -- each run ends on an rx- marker only its script
# prints, and the stage gates forward on the app's own `gosheet:` markers; a
# program that never ran cannot pass.

vgate_name go-sheet "issue #2789 M142a: a Go spreadsheet recalculates a SUM on edit and refuses a cycle with #CYCLE, probed on pixels"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOSHEET.ELF
EOF

vgate_file script3.txt <<'EOF'
echo rx-gosheet-01
EOF

vgate_file script3-02.txt <<'EOF'
echo rx-gosheet-02
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOSHEET.ELF")
if not os.path.exists(src):
    sys.exit("GOSHEET.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gosheet.sh")
shutil.copy(src, os.path.join(share, "GOSHEET.ELF"))
seat = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(seat):
    sys.exit("GOTABWM.ELF missing (expected " + seat + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(seat, os.path.join(share, "GOTABWM.ELF"))
# Keep the seat's autostart OFF: runs 01-05 assert the bare shim's fixed
# (64,48) window geometry and 'declare refused', and run 06 execs
# GOTABWM.ELF explicitly after `wm` switches the mode (the go-paint.spec
# runs 02/03 convention).
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
# M142b (#2790) fixtures. SMALL.CSV exercises quoted-comma fields through
# the FilePicker open; BIG.CSV's used box serializes past the 512-byte
# clipboard bound so run 05's ctrl-c must refuse clip-too-large — and its
# CRLF framing makes the expected export a byte-exact copy.
small = b"alpha,42,\"be,ta\"\r\n"
with open(os.path.join(share, "SMALL.CSV"), "wb") as f:
    f.write(small)
big = b"".join(b",".join(("f%d%d" % (r, c)).encode()
                         for c in range(8)) + b"\r\n" for r in range(32))
with open(os.path.join(share, "BIG.CSV"), "wb") as f:
    f.write(big)
print("staged GOSHEET/GOTABWM + wm=none + SMALL.CSV (%d) BIG.CSV (%d)"
      % (len(small), len(big)))
PY

# --- run 01: values, a SUM, and the recalculation leg -----------------------
# Chord trace (grid starts focused on A1; a printable char seeds the edit
# line, 'return' commits it):
#   A1 <- '2'; down -> A2 <- '3'; up,right -> B1 <- '=sum[a1:a2]' -> 5;
#   left -> A1 <- '10' -> B1 recalcs to 13; right,right -> C1 so no probed
#   cell sits under the selection highlight.
# The 20 s settle after the last recalc marker lets the repaint land before
# the echo that triggers the kind-4 snapshot (the calc run-05 idiom).
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script.txt' \
    --input-chords '2,return,down,3,return,up,right,=,s,u,m,[,a,1,:,a,2,],return,left,1,0,return,right,right' \
    --input-chords-after 'gosheet: present' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gosheet: recalc B1 -> 13' \
    --script3-delay 20 \
    --snapshot-after 'rx-gosheet-01' \
    --script-expect 'rx-gosheet-01' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOSHEET.ELF'
vgate_assert 01 serial-contains 'gosheet: open id='
vgate_assert 01 serial-contains 'gosheet: declare refused'
vgate_assert 01 serial-contains 'gosheet: present'
vgate_assert 01 serial-contains "gosheet: set A1 := '2' -> 2"
vgate_assert 01 serial-contains "gosheet: set A2 := '3' -> 3"
vgate_assert 01 serial-contains "gosheet: set B1 := '=sum[a1:a2]' -> 5"
vgate_assert 01 serial-contains "gosheet: set A1 := '10' -> 10"
vgate_assert 01 serial-contains 'gosheet: recalc B1 -> 13'
vgate_assert 01 serial-contains 'rx-gosheet-01'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The pixel probe. Geometry (canvas coords; scanout adds the 64,48 window
# origin): the table plate is {8,48,656,344}; inside the 1px border the
# 22px header band leaves the body at {9,70,654,321}, rowH=20 paints row r
# at y=70+20r, and column c (64px wide) at x=9+64c while ScrollTop/ScrollX
# stay 0 — all probed cells sit inside the untouched top-left window. Cell
# text is drawGlyphRun: plate inset 2, the 8-row glyph band centred in the
# 16px inner height, 8px advance — so cell (r,c)'s glyph zone starts at
# (9+64c+2, 70+20r+6) canvas = (75+64c, 124+20r) scanout. Each character
# decodes by matching its 8x8 lit-mask against Font8x8 read from the repo.
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import re, sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %d" % (len(raw), W * H * 4))

def px(x, y):
    off = (y * W + x) * 4
    b, g, r = raw[off], raw[off + 1], raw[off + 2]
    return (r, g, b)

# Font table from the checked-in Go source — the same data drawGlyphRun
# paints; index i is ASCII 0x20+i, bit 0 the leftmost pixel.
font = []
src = open("user/go/webrender/font/font8x8.go").read()
for m in re.finditer(r"\{((?:0x[0-9a-fA-F]{2},\s*){7}0x[0-9a-fA-F]{2})\}", src):
    font.append(tuple(int(b, 16) for b in m.group(1).split(",")))
if len(font) != 95:
    sys.exit("font table parse found %d glyphs, want 95" % len(font))

def cell_origin(row, col):
    # scanout origin of cell (row,col)'s glyph zone; see the spec comment.
    return (75 + 64 * col, 124 + 20 * row)

def cell_bg(x0, y0):
    # The cell interior is a uniform fill (Surface, or Selection for the
    # focused cell); sample a corner far from the glyph band.
    return px(x0 - 1 + 30, y0 - 2)

def decode_cell(row, col, limit=8):
    x0, gy = cell_origin(row, col)
    bg = cell_bg(x0, gy)
    out = []
    for i in range(limit):
        mask = []
        for dy in range(8):
            bits = 0
            for dx in range(8):
                if px(x0 + i * 8 + dx, gy + dy) != bg:
                    bits |= 1 << dx
            mask.append(bits)
        if not any(mask):
            break  # blank glyph slot: end of the cell's text
        try:
            out.append(chr(0x20 + font.index(tuple(mask))))
        except ValueError:
            sys.exit("cell %d,%d char %d: mask %r matches no glyph"
                     % (row, col, i, mask))
    return "".join(out)

want = {(0, 0): "10", (1, 0): "3", (0, 1): "13"}
for (row, col), text in sorted(want.items()):
    got = decode_cell(row, col)
    if got != text:
        sys.exit("cell r%d c%d decodes %r, want %r" % (row, col, got, text))
    print("cell r%d c%d = %r" % (row, col, got))
PY

# --- run 02: the cycle refusal + the other three error codes ----------------
# A1 <- '=b1' (B1 empty -> displays 0); B1 <- '=a1' closes the loop;
# C1 <- '=1/0'; D1 <- '=zz1' (column ZZ is outside DX); E1 <- '=foo'.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-02' \
    --script '$RUN_DIR/script.txt' \
    --input-chords '=,b,1,return,right,=,a,1,return,right,=,1,/,0,return,right,=,z,z,1,return,right,=,f,o,o,return' \
    --input-chords-after 'gosheet: present' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after "gosheet: set E1 := '=foo' -> #PARSE" \
    --script3-delay 20 \
    --snapshot-after 'rx-gosheet-02' \
    --script-expect 'rx-gosheet-02' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded GOSHEET.ELF'
vgate_assert 02 serial-contains 'gosheet: open id='
vgate_assert 02 serial-contains 'gosheet: declare refused'
vgate_assert 02 serial-contains 'gosheet: present'
vgate_assert 02 serial-contains "gosheet: set A1 := '=b1' -> 0"
vgate_assert 02 serial-contains "gosheet: set B1 := '=a1' -> #CYCLE"
vgate_assert 02 serial-contains 'gosheet: recalc A1 -> #CYCLE'
vgate_assert 02 serial-contains 'gosheet: cycle A1,B1'
vgate_assert 02 serial-contains "gosheet: set C1 := '=1/0' -> #DIV/0"
vgate_assert 02 serial-contains "gosheet: set D1 := '=zz1' -> #REF"
vgate_assert 02 serial-contains "gosheet: set E1 := '=foo' -> #PARSE"
vgate_assert 02 serial-contains 'rx-gosheet-02'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

vgate_assert 02 snapshot 'snap-02-*.raw' <<'PY'
import re, sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %d" % (len(raw), W * H * 4))

def px(x, y):
    off = (y * W + x) * 4
    b, g, r = raw[off], raw[off + 1], raw[off + 2]
    return (r, g, b)

font = []
src = open("user/go/webrender/font/font8x8.go").read()
for m in re.finditer(r"\{((?:0x[0-9a-fA-F]{2},\s*){7}0x[0-9a-fA-F]{2})\}", src):
    font.append(tuple(int(b, 16) for b in m.group(1).split(",")))
if len(font) != 95:
    sys.exit("font table parse found %d glyphs, want 95" % len(font))

def decode_cell(row, col, limit=8):
    x0, gy = 75 + 64 * col, 124 + 20 * row
    bg = px(x0 + 29, gy - 2)
    out = []
    for i in range(limit):
        mask = []
        for dy in range(8):
            bits = 0
            for dx in range(8):
                if px(x0 + i * 8 + dx, gy + dy) != bg:
                    bits |= 1 << dx
            mask.append(bits)
        if not any(mask):
            break
        try:
            out.append(chr(0x20 + font.index(tuple(mask))))
        except ValueError:
            sys.exit("cell %d,%d char %d: mask %r matches no glyph"
                     % (row, col, i, mask))
    return "".join(out)

want = {(0, 0): "#CYCLE", (0, 1): "#CYCLE", (0, 2): "#DIV/0",
        (0, 3): "#REF", (0, 4): "#PARSE"}
for (row, col), text in sorted(want.items()):
    got = decode_cell(row, col)
    if got != text:
        sys.exit("cell r%d c%d decodes %r, want %r" % (row, col, got, text))
    print("cell r%d c%d = %r" % (row, col, got))
PY

# --- M142b (issue #2790) ---------------------------------------------------
#
# run 03: the paste leg. `clip '7,"e,f",9'` seeds the kernel buffer with a
# quoted-comma CSV row; ctrl-v fills A1:C1 from the cursor (the pasted
# region becomes the selection), escape drops it, ctrl-shift-m at A1 +
# right re-selects A1:B1, and ctrl-c stores `7,"e,f"` on the text/csv lane.
# script3's bare `clip` reads the kernel buffer back — serial carries the
# copied bytes verbatim. `exec -u0` is the CAP_CLIPBOARD path.
vgate_file script-03.txt <<'EOF'
clip '7,"e,f",9'
exec -u0 GOSHEET.ELF
EOF

vgate_file script3-03.txt <<'EOF'
clip
echo rx-gosheet-03
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-03' \
    --script '$RUN_DIR/script-03.txt' \
    --input-chords 'ctrl-v,escape,home,ctrl-shift-m,right,ctrl-c' \
    --input-chords-after 'gosheet: present' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'gosheet: copy ' \
    --script3-delay 20 \
    --snapshot-after 'rx-gosheet-03' \
    --script-expect 'rx-gosheet-03' --timeout 300

vgate_assert 03 serial-contains 'clip: stored 9 bytes'
vgate_assert 03 serial-contains 'exec: loaded GOSHEET.ELF'
vgate_assert 03 serial-contains 'gosheet: declare refused'
vgate_assert 03 serial-contains 'gosheet: present'
vgate_assert 03 serial-contains 'gosheet: paste n=3'
vgate_assert 03 serial-contains 'gosheet: sel A1:C1'
vgate_assert 03 serial-contains 'gosheet: mark off'
vgate_assert 03 serial-contains 'gosheet: mark A1'
vgate_assert 03 serial-contains 'gosheet: copy A1:B1 n=9'
# The kernel buffer holds the copied text/csv bytes — the monitor's own
# `clip` prints them back to serial.
vgate_assert 03 serial-contains 'clip: 7,"e,f"'
vgate_assert 03 serial-contains 'rx-gosheet-03'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# The pasted cells on pixels: A1='7', B1='e,f' (the quoted comma landed in
# one cell), C1='9'. Same glyph-decode idiom as run 01.
vgate_assert 03 snapshot 'snap-03-*.raw' <<'PY'
import re, sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %d" % (len(raw), W * H * 4))

def px(x, y):
    off = (y * W + x) * 4
    b, g, r = raw[off], raw[off + 1], raw[off + 2]
    return (r, g, b)

font = []
src = open("user/go/webrender/font/font8x8.go").read()
for m in re.finditer(r"\{((?:0x[0-9a-fA-F]{2},\s*){7}0x[0-9a-fA-F]{2})\}", src):
    font.append(tuple(int(b, 16) for b in m.group(1).split(",")))
if len(font) != 95:
    sys.exit("font table parse found %d glyphs, want 95" % len(font))

def decode_cell(row, col, limit=8):
    x0, gy = 75 + 64 * col, 124 + 20 * row
    bg = px(x0 + 29, gy - 2)
    out = []
    for i in range(limit):
        mask = []
        for dy in range(8):
            bits = 0
            for dx in range(8):
                if px(x0 + i * 8 + dx, gy + dy) != bg:
                    bits |= 1 << dx
            mask.append(bits)
        if not any(mask):
            break
        try:
            out.append(chr(0x20 + font.index(tuple(mask))))
        except ValueError:
            sys.exit("cell %d,%d char %d: mask %r matches no glyph"
                     % (row, col, i, mask))
    return "".join(out)

want = {(0, 0): "7", (0, 1): "e,f", (0, 2): "9"}
for (row, col), text in sorted(want.items()):
    got = decode_cell(row, col)
    if got != text:
        sys.exit("cell r%d c%d decodes %r, want %r" % (row, col, got, text))
    print("cell r%d c%d = %r" % (row, col, got))
PY

# --- run 04: FilePicker open -> CSV import ---------------------------------
# ctrl-o raises the shared picker, the typed name resolves under /host, and
# the file replaces the sheet wholesale — SMALL.CSV's quoted-comma field
# lands as one cell ('be,ta'), decoded on pixels.
vgate_file script-04.txt <<'EOF'
exec GOSHEET.ELF
EOF

vgate_file script3-04.txt <<'EOF'
echo rx-gosheet-04
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-04' \
    --script '$RUN_DIR/script-04.txt' \
    --input-chords 'ctrl-o' \
    --input-chords-after 'gosheet: present' \
    --input-string 'SMALL.CSV
' \
    --input-string-after 'gosheet: pick open' \
    --script3 '$RUN_DIR/script3-04.txt' \
    --script3-after 'gosheet: import ' \
    --script3-delay 20 \
    --snapshot-after 'rx-gosheet-04' \
    --script-expect 'rx-gosheet-04' --timeout 300

vgate_assert 04 serial-contains 'exec: loaded GOSHEET.ELF'
vgate_assert 04 serial-contains 'gosheet: present'
vgate_assert 04 serial-contains 'gosheet: pick open'
vgate_assert 04 serial-contains 'gosheet: pick open /host/SMALL.CSV'
vgate_assert 04 serial-contains 'gosheet: import /host/SMALL.CSV cells=3 rows=1'
vgate_assert 04 serial-contains 'rx-gosheet-04'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

vgate_assert 04 snapshot 'snap-04-*.raw' <<'PY'
import re, sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %d" % (len(raw), W * H * 4))

def px(x, y):
    off = (y * W + x) * 4
    b, g, r = raw[off], raw[off + 1], raw[off + 2]
    return (r, g, b)

font = []
src = open("user/go/webrender/font/font8x8.go").read()
for m in re.finditer(r"\{((?:0x[0-9a-fA-F]{2},\s*){7}0x[0-9a-fA-F]{2})\}", src):
    font.append(tuple(int(b, 16) for b in m.group(1).split(",")))
if len(font) != 95:
    sys.exit("font table parse found %d glyphs, want 95" % len(font))

def decode_cell(row, col, limit=8):
    x0, gy = 75 + 64 * col, 124 + 20 * row
    bg = px(x0 + 29, gy - 2)
    out = []
    for i in range(limit):
        mask = []
        for dy in range(8):
            bits = 0
            for dx in range(8):
                if px(x0 + i * 8 + dx, gy + dy) != bg:
                    bits |= 1 << dx
            mask.append(bits)
        if not any(mask):
            break
        try:
            out.append(chr(0x20 + font.index(tuple(mask))))
        except ValueError:
            sys.exit("cell %d,%d char %d: mask %r matches no glyph"
                     % (row, col, i, mask))
    return "".join(out)

want = {(0, 0): "alpha", (0, 1): "42", (0, 2): "be,ta"}
for (row, col), text in sorted(want.items()):
    got = decode_cell(row, col)
    if got != text:
        sys.exit("cell r%d c%d decodes %r, want %r" % (row, col, got, text))
    print("cell r%d c%d = %r" % (row, col, got))
PY

# --- run 05: oversized copy refusal + FilePicker export ---------------------
# BIG.CSV lands via argv (the same import the picker reaches), ctrl-a
# selects the used box A1:H32, and ctrl-c refuses with the card's named
# reason — the serialized range (1232 bytes) is over the kernel's 512.
# ctrl-s exports through the picker; the host-side byte-compare proves
# OUT.CSV is BIG.CSV verbatim — the CRLF-framed round trip.
vgate_file script-05.txt <<'EOF'
exec -u0 GOSHEET.ELF /host/BIG.CSV
EOF

vgate_file script3-05.txt <<'EOF'
echo rx-gosheet-05
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio \
    --script '$RUN_DIR/script-05.txt' \
    --input-chords 'ctrl-a,ctrl-c,ctrl-s' \
    --input-chords-after 'gosheet: present' \
    --input-string 'OUT.CSV
' \
    --input-string-after 'gosheet: pick save' \
    --script3 '$RUN_DIR/script3-05.txt' \
    --script3-after 'gosheet: export ' \
    --script-expect 'rx-gosheet-05' --timeout 300

vgate_assert 05 serial-contains 'exec: loaded GOSHEET.ELF'
vgate_assert 05 serial-contains 'gosheet: import /host/BIG.CSV cells=256 rows=32'
vgate_assert 05 serial-contains 'gosheet: sel A1:H32'
vgate_assert 05 serial-contains 'gosheet: copy clip-too-large'
vgate_assert 05 serial-contains 'gosheet: pick save /host/OUT.CSV'
vgate_assert 05 serial-contains 'gosheet: export /host/OUT.CSV n=1232'
vgate_assert 05 serial-contains 'rx-gosheet-05'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'

# The exported bytes on the host share must be BIG.CSV verbatim — a save
# that reported success without writing those bytes cannot pass.
vgate_assert 05 python <<'PY'
import os
share = os.environ["VG_SHARE"]
want = b"".join(b",".join(("f%d%d" % (r, c)).encode()
                         for c in range(8)) + b"\r\n" for r in range(32))
got = open(os.path.join(share, "OUT.CSV"), "rb").read()
if got != want:
    import sys
    sys.exit("OUT.CSV MISMATCH: got %d bytes %r, want %d bytes"
             % (len(got), got[:64], len(want)))
print("OUT.CSV is BIG.CSV verbatim (%d bytes)" % len(got))
PY

# --- run 06: save_state through close + reopen (the seat leg) ---------------
# Under GOTABWM: A1=5, A2==a1+a1 -> 10 (the runner's chord table has no
# '*'; '+' rides shift+=), `end` + `pagedown` scroll the view off the
# origin, ctrl-shift-w closes the tab (the seat collects the state blob
# first), and ctrl-shift-t re-execs the recorded bin — the restored marker
# names the cell count, the cursor cell, and both scroll offsets.
vgate_file script-06.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-06.txt <<'EOF'
dui focus 0
exec GOSHEET.ELF
EOF

vgate_file script3-06.txt <<'EOF'
echo rx-gosheet-06
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio \
    --script '$RUN_DIR/script-06.txt' \
    --script2 '$RUN_DIR/script2-06.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords '5,return,down,=,a,1,+,a,1,return,right,end,pagedown,ctrl-shift-w,ctrl-shift-t' \
    --input-chords-after 'gosheet: present' \
    --script3 '$RUN_DIR/script3-06.txt' \
    --script3-after 'gosheet: state restored ' \
    --script-expect 'rx-gosheet-06' --timeout 300

vgate_assert 06 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 06 serial-contains 'exec: loaded GOSHEET.ELF'
vgate_assert 06 serial-contains 'gosheet: declare accepted'
vgate_assert 06 serial-contains "gosheet: set A1 := '5' -> 5"
vgate_assert 06 serial-contains "gosheet: set A2 := '=a1+a1' -> 10"
vgate_assert 06 serial-contains 'gotabwm: state ask id='
vgate_assert 06 serial-contains 'gosheet: state saved n='
vgate_assert 06 serial-contains 'gotabwm: state save id='
vgate_assert 06 serial-contains 'gotabwm: tab close id='
vgate_assert 06 serial-contains 'gosheet: close'
vgate_assert 06 serial-contains 'gosheet OK'
vgate_assert 06 serial-contains 'gotabwm: reopen GOSHEET.ELF'
vgate_assert 06 serial-contains 'rx-gosheet-06'
vgate_assert 06 serial-absent 'gosheet: state stale'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'

# The restored marker must name the two cells, a DX-column cursor
# (end-jumped), and nonzero scroll offsets — pagedown moved ScrollTop,
# end moved ScrollX. A blob that kept the sheet but dropped the view
# cannot pass.
vgate_assert 06 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], "rb").read()
m = re.search(rb"gosheet: state restored cells=(\d+) sel=([A-Z]+\d+) top=(\d+) sx=(\d+)", ser)
if not m:
    sys.exit("no 'gosheet: state restored' marker")
cells, top, sx = int(m.group(1)), int(m.group(3)), int(m.group(4))
if cells != 2 or not m.group(2).startswith(b"DX") or top == 0 or sx == 0:
    sys.exit("restored marker %r fails: want cells=2 sel=DX* top>0 sx>0" % m.group(0))
print("restored: cells=2 sel=%s top=%d sx=%d" % (m.group(2).decode(), top, sx))
PY
