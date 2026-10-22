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
# M145b (#2797) run 03: the GOSOL leg, bare shim like the GOMINE pair.
# `exec GOSOL.ELF --seed=1` deals the pinned table; three stock clicks
# fan the waste and a scripted press/move/release attempts the tab0 ->
# tab5 drag — which is UNREACHABLE today (#2878: kernel MOUSE_UP carries
# flags=0, so gosol's BtnLeft-gated up() never runs; under the seat no
# pointer reaches hosted apps at all). The serial-absent pins document
# the defect honestly; the probe reads the waste fan + tab0's face.
# Layout: stock (16,12,56,80), waste (88,12), tab p at (18+70p,108);
# canvas->scanout is +32,+32 exactly like run 01.
#
# M145c (#2798) runs 04+05: the K=3 acceptance (vgate_repeat 3). The
# seat owns the pointer stream, so "play" is the reachable input path
# — keys routed to the focused tab. Run 04 seats GOTABWM (staged as
# SEATWM.ELF so the wm=gotabwm autostart cannot seat the shim legs) and
# execs GOMINE (rail cell 0) then GOSOL (cell 1, steals focus). One
# chords batch plays both tables part way — 'd' draw-mode 3, 'n' fresh
# deal, 'alt-tab' to GOMINE, '2' the 16x16 intermediate board — and the
# trailing 'ctrl-shift-s' arms the seat snapshot, whose own quiet window
# defers the ask until every repaint has composited. The pointer batch
# then hovers rail cell 1: the FIRST 'rail-hover' marker is taken while
# GOMINE is still focused (snap-04-0 = its mid-board), the click focuses
# GOSOL with the cursor parked on the rail, and 'state ask' fires
# snap-04-1 on the GOSOL table. Run 05 boots the session restore — the
# share's GOTABWM.ELF autostarts the seat, which re-execs both rows from
# their blobs — delayed echoes give the ~1 Hz composite tick a full
# window before each kind-4 snapshot, alt-tab flips focus for the
# second, and the python compares the restored tables byte-for-byte
# (GOSOL (0,22)-(512,384), GOMINE's 16x16 grid) after proving each raw
# is fresh to its own iteration. The per-iteration GOMINE win completes
# in run 01's seeded win leg.
#
# exec-order: assert-proven -- runs 04/05 end on markers only the seat
# or apps print ('gotabwm: snapshot saved') or on script echoes anchored
# by stage gates on guest output ('gotabwm: alt-tab id=', 'session live
# n=2'), so a program that never ran cannot pass.
#
# HOST PREREQUISITES (fail the gate honestly when missing):
#   bash tools/go/build-gomine.sh   ->  .build/go/GOMINE.ELF
#   bash tools/go/build-gosol.sh    ->  .build/go/GOSOL.ELF
#   bash tools/go/build-gotabwm.sh  ->  .build/go/GOTABWM.ELF

vgate_name go-games "M145a+b+c #2796/#2797/#2798: GOMINE.ELF seeded win/loss legs + GOSOL.ELF stock-draw leg + K=3 acceptance — both games played part way under the seat, mid-game session snapshot, exact-restore pixel compare (drag leg pinned on #2878)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

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
for name, script in (("GOMINE.ELF", "build-gomine.sh"),
                     ("GOSOL.ELF", "build-gosol.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + script)
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)" %
          (name, os.path.getsize(os.path.join(share, name))))
# The seat rides under a staged name: a share-visible GOTABWM.ELF plus the
# seeded settings' wm=gotabwm autostarts the desktop on EVERY boot, which
# would seat the bare-shim legs 01-03 (declare accepted -> full-viewport ->
# the pinned coordinates all miss). Run 04 vf-mv's it into place; run 05
# mv's it back so the next iteration's run 04 also boots seatless.
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "SEATWM.ELF"))
print("staged GOTABWM.ELF as SEATWM.ELF (%d bytes)"
      % os.path.getsize(os.path.join(share, "SEATWM.ELF")))
# The seat records each tab's bin from guessBin(declared title), and
# "Mines"/"Solitaire" have no guessBin rows yet (that table is #2870's
# file) — so SESSION.TABS round-trips the TITLES as the exec names and the
# restore's re-exec looks for files literally named "Mines"/"Solitaire".
# Staging the ELFs under those recorded names lets the restore run its
# real reexec->adopt->state-push path today; when the guessBin rows land
# the recorded bins become GOMINE.ELF/GOSOL.ELF and these files are inert.
for elf, alias in (("GOMINE.ELF", "Mines"), ("GOSOL.ELF", "Solitaire")):
    shutil.copy(os.path.join(share, elf), os.path.join(share, alias))
print("staged title-named exec aliases Mines + Solitaire")
PY

# --- run 01: the seeded win leg ------------------------------------------
# Steps: reveal (4,4) floods 52 cells; the remaining 19 safe cells are
# each revealed with a left-click pair — every move is 'd;u', never an
# atomic 'rc', because a single queue-level drop on an 'rc' step eats
# the flag/chord (a toggle can't be retried, observed 3x on 01-03) while
# a dropped 'd' or 'u' never loses a reveal pair outright. The 19 cells
# are the seed-1 beginner safe list (verified against the engine:
# mines at (3,0)(3,1)(5,2)(7,4)(2,5)(8,5)(7,6)(1,7)(0,8)(1,8)). Each
# step rides behind a bare move so the guest input queue drains.
# Markers are asserted after-the-fact: the app's markers only print
# when the move landed, so the click path IS the evidence.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script.txt' \
    --pointer-virtio '392,334;392,334,d;392,334,u;392,222;392,222,d;392,222,u;420,222;420,222,d;420,222,u;448,222;448,222,d;448,222,u;476,222;476,222,d;476,222,u;504,222;504,222,d;504,222,u;392,250;392,250,d;392,250,u;420,250;420,250,d;420,250,u;448,250;448,250,d;448,250,u;476,250;476,250,d;476,250,u;504,250;504,250,d;504,250,u;448,278;448,278,d;448,278,u;476,278;476,278,d;476,278,u;504,278;504,278,d;504,278,u;476,306;476,306,d;476,306,u;504,306;504,306,d;504,306,u;504,334;504,334,d;504,334,u;476,362;476,362,d;476,362,u;504,390;504,390,d;504,390,u;280,418;280,418,d;280,418,u' \
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
vgate_assert 01 serial-contains 'gomine: reveal 4,0 n=1'
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

# The win auto-flags every mine: amber 'F' glyphs on (3,0) and (0,8).
# plate (319,177) -> glyph x 328..335 -> scanout 360..367, y 218..225.
n1 = glyph_count(360, 218, FLAG, "auto-flag at (3,0)")
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

# --- run 03 (M145b #2797): the GOSOL boot + stock-draw leg, bare shim -------
# exec GOSOL.ELF --seed=1 under the bare shim. Three stock clicks fan the
# waste to its full three-card spread ('draw n=1' x3); the pixel probe
# reads the three fanned faces and a tableau card.
#
# The in-surface drag gesture is still unresolved on this raw-shim path
# (observed 2026-10-26: with #2878 in the kernel, the press/move/release
# below produces NEITHER 'move' nor 'drop bad' — gosol's BtnLeft-gated
# up() never runs — while run 04's seat-hosted content-pointer clicks DO
# reach GOMINE and play a win). The serial-absent lines pin that broken
# state honestly; the pixel probe reads the card still mid-flight at the
# last pointer position. When the raw path's release flags are fixed the
# gesture resolves a legal move tab0->tab5 and these asserts flip to
# serial-contains plus the face/'J'-ink probes at tab5's top card.
vgate_file script-gosol.txt <<'EOF'
exec GOSOL.ELF --seed=1
EOF

vgate_file script3-gosol.txt <<'EOF'
echo rx-gosol-03
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-03' \
    --script '$RUN_DIR/script-gosol.txt' \
    --pointer-virtio '76,84,d;76,84,u;76,84,d;76,84,u;76,84,d;76,84,u;78,180,d;90,190;200,200;300,215;428,232,u' \
    --pointer-virtio-after 'gosol: ready' \
    --snapshot-after 'rx-gosol-03' \
    --script3 '$RUN_DIR/script3-gosol.txt' \
    --script3-after 'gosol: draw n=1' --script3-delay 35 \
    --script-expect 'rx-gosol-03' --timeout 240

vgate_assert 03 serial-contains 'exec: loaded GOSOL.ELF'
vgate_assert 03 serial-contains 'gosol: open id='
vgate_assert 03 serial-contains 'gosol: not-tab-aware (shim or WND desktop)'
vgate_assert 03 serial-contains 'gosol: deal seed=1 draw=1'
vgate_assert 03 serial-contains 'gosol: ready'
vgate_assert 03 serial-count 'gosol: draw n=1' 3
# Observed: the drop cannot resolve on this path — the release reaches
# gosol without BtnLeft so up() never runs (see header comment).
vgate_assert 03 serial-absent 'gosol: move tab0->tab5'
vgate_assert 03 serial-absent 'gosol: drop bad'
vgate_assert 03 serial-contains 'rx-gosol-03'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# Pixel probes, canvas->scanout +32,+32. Three waste cards fan right at
# canvas x=88/100/112 (face interiors at y 50..60); tab0's lifted card
# flies at canvas (368,160)-(424,240) -> interior scanout (410..450,
# 205..245). When the drop resolves the card lands on tab5 and this
# probe moves to tab5's top card at home.
vgate_assert 03 snapshot 'snap-03-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %d" % (len(raw), W * H * 4))

def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])  # BGRX -> RGB

FACE    = (0xf6, 0xf3, 0xec)  # card face
TITLE   = (0x1a, 0x2b, 0x3c)  # kernel title band

band = [px(x, y) for y in range(34, 46) for x in range(60, 700, 10)]
if sum(1 for c in band if c == TITLE) * 2 < len(band):
    sys.exit("title band rows are not the kernel chrome colour")

def count(x0, y0, w, h, want):
    return sum(1 for y in range(y0, y0 + h) for x in range(x0, x0 + w)
               if px(x, y) == want)

for i, x in enumerate((124, 136, 148)):
    if count(x, 60, 8, 10, FACE) < 60:
        sys.exit("waste fan slot %d shows no card face" % i)
if count(410, 205, 40, 40, FACE) < 1000:
    sys.exit("the lifted card is not rendering mid-flight at the pointer")
print("gosol: waste fanned to 3 faces, dragged card flying")
PY


# --- run 04 (M145c #2798): the play + snapshot boot, seat-hosted -------------
# Under GOTABWM apps receive keyboard input only — the seat owns the pointer
# stream and delivers none of it to bound apps (#2878), so "play" here is
# the reachable input path: keys, routed to the focused tab.
#
# Visibility model (observed, pinned honestly): the seat composites EVERY
# live shared surface in DECLARE order — a full-viewport tab covers every
# earlier one and focus never restacks, so exactly one table is visible at
# a time unless the windows are TILED. 'ctrl-shift-v' (split V) proposes
# pane rects through wmctlSetWindowRect; the windows take them, the
# surfaces relayout to pane size, and composeSurfaces draws each at its
# mirrored rect — both tables in one scanout.
#
# Choreography: GOMINE execs first and is PLAYED TO A WIN while it's the
# only tab — #2878's content forward delivers pointer into the lone
# full-viewport pane, so the same seed-1 beginner cell list as run 01
# (re-mapped to pane coords: canvas is the whole 1280x720 surface, cells
# 28px on a grid at (514,256) -> scanout (528+28x, 270+28y)) drives the
# real reveal path. The win records beginner's best time; input-string
# '2' then reseeds the 16x16 intermediate board — the record stays in
# the process and the snapshot's blob carries it, which is what run 05's
# restore shows surviving.
# GOSOL execs second, steals focus on declare; ONE late chords batch on
# 'gosol: ready' does 'd' -> draw-mode 3, 'n' -> a fresh deal, then
# 'ctrl-shift-v' splits the FOCUSED (Solitaire's) pane — Solitaire keeps
# its leaf, Mines fills the other — and 'ctrl-shift-s' arms the state
# ask. 'snapshot saved bytes=' anchors snap-04-0 — the bundle write
# follows both state saves, deep enough past the split's WIN_RESIZE +
# repaint that the frame is settled (anchoring on 'state ask' raced the
# repaint once — a black band in the pane, observed). The save records
# focus on Solitaire, which makes the restore boot split the SAME pane
# (see run 05).
vgate_file script-04.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SNAPSHOT.BUNDLE
vf rm NOTIFY.HIST
vf rm GOTABWM.ELF
vf mv SEATWM.ELF GOTABWM.ELF
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-04.txt <<'EOF'
exec GOMINE.ELF 1 0
EOF

vgate_file script3-04.txt <<'EOF'
exec GOSOL.ELF --seed=1
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-04' \
    --script '$RUN_DIR/script-04.txt' \
    --script2 '$RUN_DIR/script2-04.txt' --script2-after 'gotabwm: win focus' \
    --pointer-virtio '640,382,d;640,382,u;640,270,d;640,270,u;668,270,d;668,270,u;696,270,d;696,270,u;724,270,d;724,270,u;752,270,d;752,270,u;640,298,d;640,298,u;668,298,d;668,298,u;696,298,d;696,298,u;724,298,d;724,298,u;752,298,d;752,298,u;696,326,d;696,326,u;724,326,d;724,326,u;752,326,d;752,326,u;724,354,d;724,354,u;752,354,d;752,354,u;752,382,d;752,382,u;724,410,d;724,410,u;752,438,d;752,438,u;528,466,d;528,466,u' \
    --pointer-virtio-after 'gomine: present' \
    --input-string '2' \
    --input-string-after 'gomine: chime' \
    --script3 '$RUN_DIR/script3-04.txt' --script3-after 'size=intermediate' \
    --script3-delay 3 \
    --input-chords 'd,n,ctrl-shift-v,ctrl-shift-s' \
    --input-chords-after 'gosol: ready' \
    --snapshot-after 'gotabwm: snapshot saved bytes=' \
    --script-expect 'gotabwm: snapshot saved bytes=' --timeout 420

vgate_assert 04 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 04 serial-contains 'gotabwm: mode live'
vgate_assert 04 serial-contains 'exec: loaded GOMINE.ELF'
vgate_assert 04 serial-contains 'gomine: open id='
vgate_assert 04 serial-contains 'gomine: declare accepted'
vgate_assert 04 serial-contains 'gomine: seed 1 size=beginner'
vgate_assert 04 serial-contains 'gomine: present'
# The seeded win under the seat: the content forward's clicks play the
# board out, the record line names beginner's best, the chime reports
# its verdict (no audio device in the gate VM -> silent no-device).
vgate_assert 04 serial-contains 'gomine: win t='
vgate_assert 04 serial-contains 'gomine: best beginner='
vgate_assert 04 serial-contains 'gomine: chime'
vgate_assert 04 serial-contains 'exec: loaded GOSOL.ELF'
vgate_assert 04 serial-contains 'gosol: open id='
vgate_assert 04 serial-contains 'gosol: tab-aware (full-viewport)'
vgate_assert 04 serial-contains 'gosol: deal seed=1 draw=1'
vgate_assert 04 serial-contains 'gosol: ready'
vgate_assert 04 serial-contains 'size=intermediate'
vgate_assert 04 serial-contains 'gosol: draw-mode 3'
vgate_assert 04 serial-count 'gosol: deal seed=' 2
vgate_assert 04 serial-contains 'gotabwm: split v'
vgate_assert 04 serial-count 'gotabwm: state ask id=' 2
vgate_assert 04 serial-contains 'gomine: state saved len='
vgate_assert 04 serial-contains 'gosol: state save len='
vgate_assert 04 serial-count 'gotabwm: state save id=' 2
vgate_assert 04 serial-contains 'gotabwm: snapshot saved bytes='
vgate_assert 04 serial-absent 'gosol: drop bad'
vgate_assert 04 serial-absent 'gomine: boom'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

# snap-04-0: the split-V frame — Solitaire's focused pane divided
# left/right; one pane holds the dealt GOSOL table (Accent backs at
# (17,72)-(492,156) measured) and the other GOMINE's 16x16 board (CELL
# plates). The probe just proves both games painted somewhere in the
# interior rows; the byte-exact pairing lives in the run-05 compare.
vgate_assert 04 snapshot 'snap-04-0.raw' <<'PY'
import sys
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %d" % (len(raw), W * H * 4))

def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])

CELL   = (0x2d, 0x37, 0x48)
ACCENT = (0x3b, 0x82, 0xf6)

def count(x0, x1, want):
    return sum(1 for y in range(24, 690, 3) for x in range(x0, x1, 3)
               if px(x, y) == want)

half = (0, 640), (640, 1280)
sides = []
for lo, hi in half:
    c = count(lo, hi, CELL)
    a = count(lo, hi, ACCENT)
    sides.append(("mine" if c > a else "sol", c, a))
if len(set(s[0] for s in sides)) != 2:
    sys.exit("split panes do not hold one table each: %r" % sides)
print("split frame: %s | %s" % (sides[0], sides[1]))
PY

# --- run 05 (M145c #2798): the restore boot ---------------------------------
# No rm's and no seat exec: run 04's mv left GOTABWM.ELF on the share, so
# this boot autostarts the seat ('wm: autostart gotabwm'), which loads
# SESSION.TABS itself — the restore IS the leg. Both rows re-exec with
# their blobs in the recorded order AND the saved pane tree — the
# restore rebuilds run 04's split-V itself, so both surfaces tile to
# the same pane rects (the seat stacks full-viewport surfaces by
# declare order; without the saved split only the last-declared would
# ever be visible). script3 echoes rx-sol-up 14 s after 'session
# live n=2' — past the reexec, relayout and repaint — and snap-05-0
# lands both restored tables in one frame. The boot script's `vf mv`
# puts SEATWM.ELF back unconditionally so the next iteration's
# bare-shim legs never seat.
vgate_file script-05.txt <<'EOF'
set GOMAXPROCS=1
wm
vf mv GOTABWM.ELF SEATWM.ELF
EOF

vgate_file script3-05.txt <<'EOF'
echo rx-sol-up
EOF

vgate_file script2-05.txt <<'EOF'
echo rx-mine-up
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-05' \
    --script '$RUN_DIR/script-05.txt' \
    --script3 '$RUN_DIR/script3-05.txt' \
    --script3-after 'gotabwm: session live n=2' --script3-delay 14 \
    --script2 '$RUN_DIR/script2-05.txt' \
    --script2-after 'rx-sol-up' --script2-delay 1 \
    --snapshot-after 'rx-sol-up' \
    --script-expect 'rx-mine-up' --timeout 300

vgate_assert 05 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 05 serial-contains 'gotabwm: mode live'
vgate_assert 05 serial-contains 'gotabwm: session load n=2 mode=restore'
vgate_assert 05 serial-contains 'gotabwm: session reexec n=2'
# The exec names are the recorded bins — today the title-guessed
# "Mines"/"Solitaire" (resolved to the staged aliases), tomorrow the real
# ELF names once #2870 adds the guessBin rows; the count pins "both rows
# re-exec'd" without baking in which side of that fix the run saw.
vgate_assert 05 serial-count 'gotabwm: session exec ' 2
vgate_assert 05 serial-contains 'gomine: state restored size=intermediate'
# M152d: the run-04 win's beginner best rides the blob — the restore
# prints it back out of the record section.
vgate_assert 05 serial-contains 'gomine: best beginner='
vgate_assert 05 serial-contains 'gosol: restored moves='
vgate_assert 05 serial-contains 'gosol: ready'
vgate_assert 05 serial-contains 'gotabwm: session live n=2'
vgate_assert 05 serial-contains 'rx-sol-up'
vgate_assert 05 serial-contains 'rx-mine-up'
# The restore rebuilds the pane tree silently (no 'split v' chord marker),
# so the pane-sized re-share is the evidence: a 640x720 'surf live' can
# only come from a split-V pane rect.
vgate_assert 05 serial-contains '640x720' 
vgate_assert 05 serial-absent 'gosol: deal seed='
vgate_assert 05 serial-absent 'gomine: boom'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'

# The exact-restore compare. The split-V frame holds one game per pane
# (the seat's surface stacking makes a stacked capture impossible —
# observed: the last-declared surface always covers earlier ones, and
# the live order between the two restored apps is racy). Each side is
# identified by signature (CELL plates = GOMINE, Accent backs = GOSOL),
# then its interior is byte-compared against the same side of the OTHER
# boot's frame — same pane rect, so byte-exact means a restored table
# repaints pixel-perfect.
vgate_assert 05 python <<'PY'
import os, sys

rd = os.environ["RUN_DIR"]
tag = os.environ["VG_TAG"]
it = tag.rsplit("-", 1)[-1]

def fresh(raw_name, ser_name):
    rp = os.path.join(rd, raw_name)
    sp = os.path.join(rd, ser_name)
    if not os.path.exists(rp):
        sys.exit("%s missing" % raw_name)
    if not os.path.exists(sp):
        sys.exit("%s missing (no serial?)" % ser_name)
    m = os.path.getmtime(rp)
    try:
        born = os.stat(sp).st_birthtime
    except AttributeError:
        born = os.path.getmtime(sp)
    if m < born:
        sys.exit("%s (mtime %d) predates %s (birth %d) - stale raw"
                 % (raw_name, m, ser_name, born))
    return open(rp, "rb").read()

pre  = fresh("snap-04-0.raw", "vm-serial-04-%s.log" % it)
post = fresh("snap-05-0.raw", os.path.basename(os.environ["VG_SER"]))

W, H = 1280, 720
need = W * H * 4
for name, r in (("snap-04-0", pre), ("snap-05-0", post)):
    if len(r) < need:
        sys.exit("%s is %d bytes, want %d" % (name, len(r), need))

CELL   = bytes((0x48, 0x37, 0x2d, 0xff))
ACCENT = bytes((0xf6, 0x82, 0x3b, 0xff))

def side_sig(raw, x0, x1):
    c = a = 0
    for y in range(24, 690, 3):
        for x in range(x0, x1, 3):
            px = raw[(y * W + x) * 4:(y * W + x) * 4 + 4]
            if px == CELL: c += 1
            elif px == ACCENT: a += 1
    return "mine" if c > a else "sol", c, a

sides = [(0, 640), (640, 1280)]
pre_sig  = [side_sig(pre,  *sd) for sd in sides]
post_sig = [side_sig(post, *sd) for sd in sides]

for want, label in (("mine", "GOMINE"), ("sol", "GOSOL")):
    pi = [i for i, s in enumerate(pre_sig) if s[0] == want]
    qi = [i for i, s in enumerate(post_sig) if s[0] == want]
    if len(pi) != 1 or len(qi) != 1:
        sys.exit("%s not uniquely found: pre=%r post=%r" % (label, pre_sig, post_sig))
    i, j = pi[0], qi[0]
    x0a, x1a = sides[i]
    x0b, x1b = sides[j]
    n = 0
    first = None
    for y in range(22, 695):
        for x in range(3, 637):
            oa = (y * W + (x0a + x)) * 4
            ob = (y * W + (x0b + x)) * 4
            if pre[oa:oa + 4] != post[ob:ob + 4]:
                n += 1
                if first is None:
                    first = (x0a + x, y, pre[oa:oa + 4].hex(),
                             x0b + x, post[ob:ob + 4].hex())
    if n:
        sys.exit("%s pane: %d px differ pre/post restore; first at %r"
                 % (label, n, first))
print("restore-exact: both split panes byte-identical pre/post")
PY

# --- run 06 (M152d #2918): undo-in-blob + stats + chime -----------------------
# One boot, seat-hosted on an EMPTY strip (SESSION.TABS removed so the
# autostart does not replay run 04's session). GOSOL.ELF --seed=59 execs
# into the lone full-viewport pane; the 'a' key's auto-move — the
# keyboard path the card adds for exactly this reachability — plays the
# class-A-pinned deal to a real win (~126 presses; 150 sent, extra are
# no-ops on a won table). The win prints the stats line and the chime
# verdict (no audio device in the gate VM -> 'chime silent no-device').
# Then the seat's own close+reopen round trip stands in for snapshot +
# restore in one boot: 'ctrl-shift-w' issues the bounded save ask and
# drops the blob (which now carries the undo stack and the record) onto
# the reopen LIFO; 'ctrl-shift-t' re-execs "Solitaire" and the close-time
# blob comes back down restore_state — a won table whose undo history
# survived. '--input-key 32' sends 'u' only AFTER 'gosol: restored
# moves=', so 'gosol: undo depth=' can only print because history rode
# the blob.
vgate_file script-06.txt <<'EOF'
vf rm SESSION.TABS
vf rm SNAPSHOT.BUNDLE
vf rm NOTIFY.HIST
vf rm GOTABWM.ELF
vf mv SEATWM.ELF GOTABWM.ELF
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
vf mv GOTABWM.ELF SEATWM.ELF
EOF

vgate_file script2-06.txt <<'EOF'
exec GOSOL.ELF --seed=59
EOF

vgate_file script3-06.txt <<'EOF'
echo rx-games-06
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio \
    --script '$RUN_DIR/script-06.txt' \
    --script2 '$RUN_DIR/script2-06.txt' --script2-after 'gotabwm: mode live' \
    --input-string 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    --input-string-after 'gosol: ready' \
    --input-chords 'ctrl-shift-w,ctrl-shift-t' \
    --input-chords-after 'gosol: chime' \
    --input-key 32 \
    --input-key-after 'gosol: restored moves=' \
    --script3 '$RUN_DIR/script3-06.txt' \
    --script3-after 'gosol: undo depth=' --script3-delay 3 \
    --script-expect 'rx-games-06' --timeout 300

vgate_assert 06 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 06 serial-contains 'gotabwm: mode live'
vgate_assert 06 serial-contains 'exec: loaded GOSOL.ELF'
vgate_assert 06 serial-contains 'gosol: tab-aware (full-viewport)'
vgate_assert 06 serial-contains 'gosol: deal seed=59 draw=1'
vgate_assert 06 serial-contains 'gosol: ready'
vgate_assert 06 serial-contains 'gosol: win moves='
vgate_assert 06 serial-contains 'gosol: stats played=1 won=1 streak=1 best='
vgate_assert 06 serial-contains 'gosol: chime'
vgate_assert 06 serial-contains 'gotabwm: reopen '
vgate_assert 06 serial-contains 'gosol: restored moves='
# The stats line prints twice — once at the win, once off the restored
# blob — proving the record survived the close/reopen round trip.
vgate_assert 06 serial-count 'gosol: stats played=1 won=1 streak=1' 2
# 'u' fires only after the restore marker: the undo succeeds only
# because the undo stack rode the blob.
vgate_assert 06 serial-contains 'gosol: undo depth='
vgate_assert 06 serial-contains 'rx-games-06'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'

# --- run 07 (#2940): the enforce leg — both games' saves under enforce ------
# A run-scoped share (`--cvc-file`, the go-agentd posture-leg pattern: a
# later --cvc-file in a run's own flags overrides the armed share for that
# boot only) carries a GRANTS.TXT of `#v1 mode=enforce` and NO user rows,
# so the compiled base rows decide — under #2939's table GOMINE.ELF and
# GOSOL.ELF rows both carry `file`, so the save_ask's staged
# /host/APPSTATE.<win> writes land from both apps. A row that still lacked
# `file` would fail BY NAME — `refused:file_denied name=<BIN> word=file`
# and the app's save marker simply never prints — never quietly; the
# asserts pin that refusal's absence AND the audit receipt's absence (the
# enforce posture), while the python hook proves the share's GRANTS.TXT
# really carried mode=enforce.
#
# Choreography (run 04's seat-hosted shape, minus the pointer win and the
# split): the setup's staged SEATWM.ELF lands renamed to GOTABWM.ELF on the
# enforce copy — a one-time rename, not a per-boot vf mv — and wm=none
# keeps autostart off so the boot script's `vf rm`s guarantee iteration-
# clean state. GOMINE execs first and '2' reseeds the 16x16 intermediate
# board (non-default); GOSOL execs second, steals focus, and 'd' + 'n'
# give it draw-mode 3 and a fresh deal (non-default). 'ctrl-shift-s' then
# asks every bound tab: both apps stage APPSTATE.<win> under their own
# rows and the seat stores both blobs before the bundle write.

vgate_setup_python <<'PY'
# Declared LAST of this spec's setup hooks so the copy sees the armed
# share's final state (SEATWM.ELF + the title aliases included), then
# layers the enforce posture on top.
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
enf = os.path.join(os.environ["RUN_DIR"], "enf-share")
if os.path.exists(enf):
    shutil.rmtree(enf)
shutil.copytree(share, enf)
# The seat rides under its real name on the enforce copy: runs 01-06 keep
# it staged as SEATWM.ELF so their boots never seat, but this leg wants
# the seat every iteration with no vf mv dance to undo.
os.replace(os.path.join(enf, "SEATWM.ELF"), os.path.join(enf, "GOTABWM.ELF"))
open(os.path.join(enf, "GRANTS.TXT"), "w").write("#v1 mode=enforce\n")
open(os.path.join(enf, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
print("enf-share: %d files, GOTABWM.ELF in place, GRANTS.TXT mode=enforce"
      % len(os.listdir(enf)))
PY

vgate_file script-07.txt <<'EOF'
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm NOTIFY.HIST
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-07.txt <<'EOF'
exec GOMINE.ELF 1 0
EOF

vgate_file script3-07.txt <<'EOF'
exec GOSOL.ELF --seed=1
EOF

vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --via-virtio \
    --cvc-file '$RUN_DIR/enf-share' \
    --script '$RUN_DIR/script-07.txt' \
    --script2 '$RUN_DIR/script2-07.txt' --script2-after 'gotabwm: mode live' \
    --input-string '2' --input-string-after 'gomine: present' \
    --script3 '$RUN_DIR/script3-07.txt' --script3-after 'size=intermediate' --script3-delay 3 \
    --input-chords 'd,n,ctrl-shift-s' --input-chords-after 'gosol: ready' \
    --script-expect 'gotabwm: snapshot saved bytes=' --timeout 300

vgate_assert 07 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 07 serial-contains 'gotabwm: mode live'
vgate_assert 07 serial-contains 'exec: loaded GOMINE.ELF'
vgate_assert 07 serial-contains 'gomine: declare accepted'
vgate_assert 07 serial-contains 'gomine: seed 1 size=beginner'
vgate_assert 07 serial-contains 'gomine: present'
# The '2' key reseeded the intermediate board — non-default state in the
# blob the save_ask collects.
vgate_assert 07 serial-contains 'size=intermediate'
vgate_assert 07 serial-contains 'exec: loaded GOSOL.ELF'
vgate_assert 07 serial-contains 'gosol: open id='
vgate_assert 07 serial-contains 'gosol: deal seed=1 draw=1'
vgate_assert 07 serial-contains 'gosol: ready'
vgate_assert 07 serial-contains 'gosol: draw-mode 3'
vgate_assert 07 serial-count 'gosol: deal seed=' 2
# The ask -> both apps' staged blobs -> stored -> bundle chain, end to
# end. `gomine: state saved len=`/`gosol: state save len=` print only on
# the acked handoff — under a missing `file` word the APPSTATE.<win>
# write is refused EACCES and the marker never prints.
vgate_assert 07 serial-count 'gotabwm: state ask id=' 2
vgate_assert 07 serial-contains 'gomine: state saved len='
vgate_assert 07 serial-contains 'gosol: state save len='
vgate_assert 07 serial-count 'gotabwm: state save id=' 2
vgate_assert 07 serial-contains 'gotabwm: snapshot saved bytes='
# The enforce posture's named failures, absent by name.
vgate_assert 07 serial-absent 'refused:file_denied name=GOMINE.ELF'
vgate_assert 07 serial-absent 'refused:file_denied name=GOSOL.ELF'
vgate_assert 07 serial-absent 'refused:file_denied name=GOTABWM.ELF'
vgate_assert 07 serial-absent 'refused:'
vgate_assert 07 serial-absent 'verdict=audit:'
vgate_assert 07 serial-absent 'gomine: boom'
vgate_assert 07 serial-absent 'gosol: drop bad'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'exited status=139'

# The share evidence (this run's share is enf-share, not the armed one —
# share-* asserts read the armed share, so the check is python): the
# GRANTS.TXT the boot read really was `#v1 mode=enforce` with no user
# rows; SESSION.TABS holds both rows with an AS trailer carrying BOTH
# apps' blobs (the envelope bytes ride no other channel than the staged
# APPSTATE.<win> write); SNAPSHOT.BUNDLE exists non-empty.
vgate_assert 07 python <<'PY'
import os, sys
sh = os.path.join(os.environ["RUN_DIR"], "enf-share")
g = open(os.path.join(sh, "GRANTS.TXT")).read()
if g != "#v1 mode=enforce\n":
    sys.exit("enforce share GRANTS.TXT is %r — not the bare enforce header"
             % g)
t = open(os.path.join(sh, "SESSION.TABS"), "rb").read()
if t[0] != 2 or t[2] != 2:
    sys.exit("SESSION.TABS header ver=%d count=%d, want ver=2 count=2"
             % (t[0], t[2]))
off = 6 + 69 * t[2]
if len(t) < off + 6 + 8 * 2 or t[off:off+2] != b"AS" or t[off+2] != 1 \
        or t[off+3] != 2:
    sys.exit("app_state trailer %r — want AS ver=1 count=2"
             % t[off:off+6])
# The trailer interleaves 8-byte entries with their blobs: ent{row,
# appver, _, _, len LE} then len bytes, per stored state.
pos = off + 6
lens = []
for i in range(2):
    ent = t[pos:pos+8]
    ln = int.from_bytes(ent[4:8], "little")
    pos += 8 + ln
    lens.append(ln)
if pos > len(t) or any(ln == 0 for ln in lens):
    sys.exit("trailer blobs truncated or empty: lens=%r tail=%d"
             % (lens, len(t) - pos))
if not os.path.getsize(os.path.join(sh, "SNAPSHOT.BUNDLE")):
    sys.exit("SNAPSHOT.BUNDLE missing or empty")
print("enforce leg: GRANTS.TXT mode=enforce; SESSION.TABS 2 rows, AS "
      "blobs %d+%d bytes; bundle present" % tuple(lens))
PY
