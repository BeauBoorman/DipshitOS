# go-games.spec -- M145a (#2796): GOMINE.ELF, the Go minesweeper, class-B
# gate. The fleet's game lane starts here; sibling cards (GOSOL #2797,
# the boot legs in M145c) extend this spec, so legs are tagged per game.
#
# user/go/gomine is a tabapp client: init -> declare (kind-8 WM_RPC) ->
# present -> EvMouseDown hit-tests the seeded board -> reveal (explicit-
# stack flood fill), flag, chord -> win raises vi.Notify -> WIN_CLOSE.
# Mines are placed lazily on the first reveal from the exec'd seed, the
# clicked cell plus neighbours excluded, so a scripted first click is
# always safe.
#
# Both legs boot the bare shim (no `tabwm start`): with a WM registered
# the kernel fans the raw pointer stream to the seat and app windows
# never see MOUSE_* (see go-calc.spec run 04's header). `declare` is
# refused, the window keeps its declared 720x560 at (32,32), and Notify
# has no seat to ack -- `gomine: notify refused` is the honest marker
# that vi.Notify ran; `ok` is the seat-hosted form.
#
#   run 01  the WIN leg. `exec GOMINE.ELF 1 0` (seed 1, beginner 9x9/10)
#           drives the exact path engine_gate_test.go pins on the host:
#           reveal (4,4) floods 52; flags on mines (3,0) and (3,1);
#           reveal (4,0); `rc` on the satisfied number chords 14 more;
#           (8,4) (7,5) (8,6) (0,7) finish the board -> `gomine: win`.
#           A kind-4 snapshot on the settled rx echo probes the flag
#           glyphs, the number ink, the revealed plate, the auto-flagged
#           mines, the "M 0 W" counter and the kernel title band.
#   run 02  the LOSS leg. Same seed; after the flood, a click on the
#           mine at (2,5) -> `gomine: boom`.
#
# Pointer coordinates: window at (32,32); beginner cells are 28px on a
# grid at canvas (234,176); cell centre scanout = (280+28x, 222+28y).
# Taps are `d`+`u` pairs, not `c` — the press must stay held across two
# pointer ticks (go-calc run 04 ate a same-tick click). `rc` is atomic.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gomine.sh   ->  .build/go/GOMINE.ELF

vgate_name go-games "M145a #2796: GOMINE.ELF — a seeded board takes a scripted click path, then flags, then wins; pixel probes pin the flag/number/mine ink"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOMINE.ELF 1 0
EOF

vgate_file script3-win.txt <<'EOF'
echo rx-gomine-win
EOF

vgate_file script3-boom.txt <<'EOF'
echo rx-gomine-boom
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOMINE.ELF")
if not os.path.exists(src):
    sys.exit("GOMINE.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gomine.sh")
shutil.copy(src, os.path.join(share, "GOMINE.ELF"))
print("staged GOMINE.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOMINE.ELF")))
PY

# --- run 01: the seeded win leg ------------------------------------------
# Steps: reveal (4,4); flag (3,0) + (3,1) via rc; reveal (4,0); rc on it
# chords (flagsAround==adj==2); four reveals finish the board. Serial
# markers are asserted after-the-fact: the app's markers only print when
# the move landed, so the click path IS the evidence.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script.txt' \
    --pointer-virtio '392,334,d;392,334,u;364,222,rc;364,250,rc;392,222,d;392,222,u;392,222,rc;504,334,d;504,334,u;476,362,d;476,362,u;504,390,d;504,390,u;280,418,d;280,418,u' \
    --pointer-virtio-after 'gomine: present' \
    --script3 '$RUN_DIR/script3-win.txt' \
    --script3-after 'gomine: win t=' \
    --script3-delay 10 \
    --snapshot-after 'rx-gomine-win' \
    --script-expect 'rx-gomine-win' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOMINE.ELF'
vgate_assert 01 serial-contains 'gomine: open id='
vgate_assert 01 serial-contains 'gomine: declare refused'
vgate_assert 01 serial-contains 'gomine: seed 1 size=beginner'
vgate_assert 01 serial-contains 'gomine: present'
vgate_assert 01 serial-contains 'gomine: reveal 4,4 n=52'
vgate_assert 01 serial-contains 'gomine: flag 3,0 on'
vgate_assert 01 serial-contains 'gomine: flag 3,1 on'
vgate_assert 01 serial-contains 'gomine: reveal 4,0 n=1'
vgate_assert 01 serial-contains 'gomine: chord 4,0 n=14'
vgate_assert 01 serial-contains 'gomine: reveal 8,4 n=1'
vgate_assert 01 serial-contains 'gomine: reveal 7,5 n=1'
vgate_assert 01 serial-contains 'gomine: reveal 8,6 n=1'
vgate_assert 01 serial-contains 'gomine: reveal 0,7 n=1'
vgate_assert 01 serial-contains 'gomine: win t='
vgate_assert 01 serial-contains 'gomine: notify refused'
vgate_assert 01 serial-contains 'rx-gomine-win'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# Pixel probes on the raw BGRX scanout (1280x720). Window (32,32); cell
# (x,y) plate canvas (234+28x+1, 176+28y+1, 26,26); glyph boxes are the
# centred 8x8 inside it -> scanout offsets (+32,+32).
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))

def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])  # BGRX -> RGB

BG      = (0x18, 0x20, 0x26)  # theme.Dark.Bg window fill
SURFACE = (0x22, 0x2d, 0x35)  # revealed cell plate
CELL    = (0x2d, 0x37, 0x48)  # hidden/flagged plate
FLAG    = (0xf5, 0x9e, 0x0b)  # flag glyph ink
GREEN2  = (0x22, 0xc5, 0x5e)  # number '2' ink
BLUE1   = (0x3b, 0x82, 0xf6)  # number '1' ink
INK     = (0xe6, 0xed, 0xf3)  # header counter ink
TITLE   = (0x1a, 0x2b, 0x3c)  # kernel title band

# Kernel chrome band over canvas rows 0..15 -> scanout rows 32..47.
band = [px(x, y) for y in range(34, 46) for x in range(60, 700, 10)]
if sum(1 for c in band if c == TITLE) * 2 < len(band):
    sys.exit("title band rows are not the kernel chrome colour")

def glyph_count(x0, y0, want, label):
    n = sum(1 for y in range(y0, y0 + 8) for x in range(x0, x0 + 8)
            if px(x, y) == want)
    if n < 4:
        sys.exit("%s: only %d %r px in the glyph box" % (label, n, want))
    return n

# Flagged mines (3,0) and the win-auto-flagged (0,8): amber 'F' glyphs.
# plate (319,177) -> glyph x 328..335 -> scanout 360..367, y 218..225.
n1 = glyph_count(360, 218, FLAG, "flag at (3,0)")
# plate (235,401) -> glyph x 244..251 -> scanout 276..283, y 442..449.
n2 = glyph_count(276, 442, FLAG, "auto-flag at (0,8)")

# Revealed number cell (4,0) '2' in green: plate (347,177) -> glyph
# x 356..363 -> scanout 388..395, y 218..225.
n3 = glyph_count(388, 218, GREEN2, "number '2' at (4,0)")

# A revealed Surface plate with no plate-face left: cell (0,6) interior.
surf = [px(x, y) for y in range(380, 400) for x in range(270, 290)]
if sum(1 for c in surf if c == SURFACE) * 2 < len(surf):
    sys.exit("cell (0,6) interior is not the revealed Surface plate")

# The win header: "M 0 W" in Ink over the counter zone (canvas 8..158 x
# 8..36 -> scanout 40..190 x 40..68). Three glyphs must paint.
hdr = sum(1 for y in range(42, 66) for x in range(44, 190) if px(x, y) == INK)
if hdr < 12:
    sys.exit("only %d Ink px in the counter zone - 'M 0 W' did not paint" % hdr)

# Outside the window is wallpaper: none of the app tokens may match.
out = px(900, 400)
if out in (BG, SURFACE, CELL, FLAG, GREEN2, BLUE1, INK, TITLE):
    sys.exit("outside-window pixel %r collides with an app token" % (out,))
print("gomine chrome: flags %d/%d px, '2' %d px, header %d Ink px" %
      (n1, n2, n3, hdr))
PY

# --- run 02: the loss leg -------------------------------------------------
# First click is safe by construction (seed-1 centre exclusion), so the
# boom needs a second click: (2,5) is a pinned seed-1 mine.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --pointer-virtio '392,334,d;392,334,u;336,362,d;336,362,u' \
    --pointer-virtio-after 'gomine: present' \
    --script3 '$RUN_DIR/script3-boom.txt' \
    --script3-after 'gomine: boom 2,5' \
    --script-expect 'rx-gomine-boom' --timeout 240

vgate_assert 02 serial-contains 'exec: loaded GOMINE.ELF'
vgate_assert 02 serial-contains 'gomine: open id='
vgate_assert 02 serial-contains 'gomine: declare refused'
vgate_assert 02 serial-contains 'gomine: seed 1 size=beginner'
vgate_assert 02 serial-contains 'gomine: present'
vgate_assert 02 serial-contains 'gomine: reveal 4,4 n=52'
vgate_assert 02 serial-contains 'gomine: reveal 2,5 n=1'
vgate_assert 02 serial-contains 'gomine: boom 2,5'
vgate_assert 02 serial-contains 'rx-gomine-boom'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
