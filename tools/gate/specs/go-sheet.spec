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
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gosheet.sh   ->  .build/go/GOSHEET.ELF
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
print("staged GOSHEET.ELF into share (%d bytes)"
      % os.path.getsize(os.path.join(share, "GOSHEET.ELF")))
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
