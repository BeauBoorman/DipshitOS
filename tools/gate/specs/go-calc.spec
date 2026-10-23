# go-calc.spec -- Go calculator (CALC.BIN successor, issue #1378; second
# pass #2201) class-B gate: a fixed-point decimal + programmer-mode calc
# opens inside Zig TABWM (or the bare shim for the pad-click leg), types a
# short expression, and reports the result.
#
# user/go/calc is a tabapp client: init -> declare (kind-8 WM_RPC) -> present
# -> accept injected keystrokes (Win_DOWN arg1 is the Unicode codepoint) or
# pointer taps (EvMouseDown hit-tests the pad) -> evaluate -> write
# /host/CALC/RESULT.TXT -> WIN_CLOSE exits. Zig CALC.BIN is gone (M62h /
# #1406). Kernel untouched.
#
# #2201 second-pass coverage:
#   run 01  the original integer regression leg (12-3=9), unchanged
#   run 02  decimal leg: '.', '/' and '+' chords drive 1.5/4=0.375 and
#           2+3.5=5.5 — fixed-point division with round-half-away, and an
#           exact decimal add (never the float 5.5000000000000004)
#   run 03  programmer keyboard leg: 'p' toggles the mode, hex digits
#           enter and display in HEX (FF-1=FE)
#   run 04  the PAD leg: --pointer-virtio clicks hit-test real pad buttons.
#           It must run under the bare shim (no seat): with a WM registered,
#           the kernel fans the raw pointer stream to the seat and never
#           delivers MOUSE_* to user windows (pointer_tick early-return,
#           driving_award); the seat's own content forward (slot-65 cmd 15)
#           only feeds terminal selection/mouse-reports, not app events.
#           Under the shim the kernel's own hit path pushes MOUSE_DOWN/UP
#           to the hit user window, so FE,AND,0F,= really clicks the pad.
#   run 05  M104h (#2275): the migrated surface, as PIXELS. Bare shim like
#           run 04 so the window keeps its declared 512x384 at (32,32); a
#           kind-4 snapshot on a settled rx echo probes the §2.2 rounded
#           pad plates (outer corner pixels stay window-Bg, never Border),
#           the Border stroke + BtnIdle faces, the bitmap '7' label ink,
#           and the Ink digits a typed '12+3' leaves in the display — the
#           draw-engine composite end-to-end, discriminated from the v1
#           flat-rect path by the corner probe.
#
# M192c (#3248) legs — the appver-1 envelope, the bounded tape, the copy verb:
#   run 06  state leg (GOTABWM): 'p' + 'f,f,-,1,return' puts the app in
#           programmer mode with one tape entry ('HEX FF-1=FE'); 't' runs
#           the copy verb — refused under a seat-launched uid_user (the
#           kernel buffer is CAP_CLIPBOARD/seat-only; the marker names the
#           rc). ctrl-shift-w closes the tab so the seat collects the
#           envelope, ctrl-shift-t re-execs: 'gocalc: state restored
#           mode=prog tape=1 last=HEX FF-1=FE' is the byte-for-byte proof
#           that mode AND tape came back.
#   run 07  the copy verb lands: `exec -u0` is the capable path (the
#           go-sheet clipboard-leg convention — a seat-launched app runs
#           uid_user without caps). 't' publishes the tape as text/plain
#           on the kernel buffer and the monitor's `clip` reads the exact
#           bytes back — 'clip: HEX FF-1=FE'.
#
# The load-bearing evidence is NOT only the app's own markers: each run's
# last assert reads the share file back ON THE HOST and requires it to
# equal the typed expression plus the result, so a stub that printed
# success without doing the arithmetic cannot pass.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gocalc.sh   ->  .build/go/GOCALC.ELF
#   bash tools/go/build-gotabwm.sh  ->  .build/go/GOTABWM.ELF  (run 06)
#
# exec-order: assert-proven -- every run ends on an rx- marker only its
# script prints, and the stage gate that forwards the close/echo waits on
# the app's own `gocalc: result ` line; a program that never ran cannot
# pass.

vgate_name go-calc "issues #1378/#2201: a fixed-point decimal + programmer-mode calc evaluates keyboard and pad input on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOCALC.ELF
EOF

# The close is driven from the harness after the app's own `gocalc: result `
# (the stage gate), so the bytes are on the share before the window closes.
vgate_file script3.txt <<'EOF'
dui close 2
echo rx-gocalc-ok
EOF

vgate_file script3-dec.txt <<'EOF'
dui close 2
echo rx-gocalc-dec-ok
EOF

vgate_file script3-prog.txt <<'EOF'
dui close 2
echo rx-gocalc-prog-ok
EOF

# Run 04 (pad leg) boots with NO seat so the kernel's own pointer path
# delivers MOUSE_* to the app window: the script is just the exec.
vgate_file script-pad.txt <<'EOF'
exec GOCALC.ELF
EOF

vgate_file script3-pad.txt <<'EOF'
echo rx-gocalc-pad-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
seat = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(seat):
    sys.exit("GOTABWM.ELF missing (expected " + seat + ") - build it first: "
             "bash tools/go/build-gotabwm.sh (run 06's seat)")
shutil.copy(seat, os.path.join(share, "GOTABWM.ELF"))
# wm=none (the go-drag convention): the seat is exec'd explicitly in run 06.
# Without it, a staged GOTABWM.ELF makes the boot autostart register the
# seat and runs 04/05 lose their bare-shim world — the pad leg's MOUSE_*
# delivery and the pixel leg's native window both require 'declare refused'.
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
calc = os.path.join(share, "CALC")
os.makedirs(calc, exist_ok=True)
print("staged GOCALC.ELF into share (%d bytes) and %s" %
      (os.path.getsize(os.path.join(share, "GOCALC.ELF")), calc))
PY

# HID chord vocabulary maps '-', '/', '=', '.', digits, letters, '+' (as
# shift-=) and return — not '&' '|' '^' '~' '<' '>' or '%' (those still work
# from a real keyboard, and run 04 drives them through the pad instead).
# 12-3=9 is the short expression this run types.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords '1,2,-,3,=' \
    --input-chords-after 'gocalc: present' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gocalc: result 12-3=9' \
    --script-expect 'rx-gocalc-ok' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'gocalc: open id='
vgate_assert 01 serial-contains 'gocalc: declare accepted'
vgate_assert 01 serial-contains 'gocalc: present'
vgate_assert 01 serial-contains 'gocalc: result 12-3=9'
vgate_assert 01 serial-contains 'gocalc: close'
vgate_assert 01 serial-contains 'gocalc OK'
vgate_assert 01 serial-contains 'rx-gocalc-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The load-bearing assert: the share file on the HOST must now hold exactly
# the typed expression plus the result. A marker that reported success
# without writing the bytes cannot pass this.
vgate_assert 01 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "CALC", "RESULT.TXT")
want = b"12-3=9\n"
got = open(path, "rb").read()
if got != want:
    print("RESULT CONTENT MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("result verified on the host: %r (%d bytes)" % (got, len(got)))
PY

# --- run 02: the decimal leg ------------------------------------------------
# Two evaluations in one boot: 1.5/4 exercises point entry + fixed-point
# division (0.375 exactly, no float), 2+3.5 exercises the '+' chord and an
# exact decimal add. The RESULT.TXT contract is last-write-wins, so the
# share assert checks the second line; both result markers are pinned on
# serial.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords '1,.,5,/,4,=,2,+,3,.,5,return' \
    --input-chords-after 'gocalc: present' \
    --script3 '$RUN_DIR/script3-dec.txt' \
    --script3-after 'gocalc: result 2+3.5=5.5' \
    --script-expect 'rx-gocalc-dec-ok' --timeout 240

vgate_assert 02 serial-contains 'tabwm: registered'
vgate_assert 02 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 02 serial-contains 'gocalc: declare accepted'
vgate_assert 02 serial-contains 'gocalc: present'
vgate_assert 02 serial-contains 'gocalc: result 1.5/4=0.375'
vgate_assert 02 serial-contains 'gocalc: result 2+3.5=5.5'
vgate_assert 02 serial-contains 'gocalc: close'
vgate_assert 02 serial-contains 'rx-gocalc-dec-ok'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

vgate_assert 02 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "CALC", "RESULT.TXT")
want = b"2+3.5=5.5\n"
got = open(path, "rb").read()
if got != want:
    print("RESULT CONTENT MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("result verified on the host: %r (%d bytes)" % (got, len(got)))
PY

# --- run 03: the programmer keyboard leg ------------------------------------
# 'p' toggles programmer mode (default base HEX), 'f'/'f' enter hex digits
# through the SAME engine calls as the pad's F button, '-' and return do
# the integer op + equals. 0xFF - 1 = 0xFE -> 'FF-1=FE'.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'p,f,f,-,1,return' \
    --input-chords-after 'gocalc: present' \
    --script3 '$RUN_DIR/script3-prog.txt' \
    --script3-after 'gocalc: result FF-1=FE' \
    --script-expect 'rx-gocalc-prog-ok' --timeout 240

vgate_assert 03 serial-contains 'tabwm: registered'
vgate_assert 03 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 03 serial-contains 'gocalc: declare accepted'
vgate_assert 03 serial-contains 'gocalc: present'
vgate_assert 03 serial-contains 'gocalc: result FF-1=FE'
vgate_assert 03 serial-contains 'gocalc: close'
vgate_assert 03 serial-contains 'rx-gocalc-prog-ok'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

vgate_assert 03 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "CALC", "RESULT.TXT")
want = b"FF-1=FE\n"
got = open(path, "rb").read()
if got != want:
    print("RESULT CONTENT MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("result verified on the host: %r (%d bytes)" % (got, len(got)))
PY

# --- run 04: the pad leg, under the shim ------------------------------------
# No `tabwm start`: the boot autostart finds no seat on the share and stays
# shim-compositing, so `declare` is refused and GOCALC keeps its native
# 512x384 window at (32,32) — exactly the coords WinOpen was called with
# (user_open stores them verbatim). Under the shim the kernel's pointer
# tick hit-tests every sample and pushes MOUSE_DOWN/UP to the hit user
# window in WINDOW-LOCAL coords — this run cannot work under a seat (see
# the header).
#
# Button centres in window-local px (PadMD=8, pad top y0=84):
#   decimal pad (5x4, btn 118x52):  P at (67,350)
#   prog pad    (6x6, btn  76x42):  F (466,155)  E (382,155)
#                                   AND (46,205)  0 (298,355)  = (466,305)
# Window at (32,32) adds the framebuffer offset:
#   P (99,382) -> prog pad; F (498,187) E (414,187) -> 'FE';
#   AND (78,237); 0 (330,387); F (498,187) -> 'FE&0F';
#   = (498,337) -> 0xFE & 0x0F = 0x0E -> 'FE&0F=E'.
# Each tap is a 'd' + 'u' pair, NOT the 'c' shorthand: the press must stay
# held across TWO shell-idle pointer ticks (the press/release edges are
# detected per tick — a down+up inside one slow tick collapses to no edge
# and the click is eaten; the run-04 'c' attempt lost the E tap exactly
# that way: observed F&0F=F). At ~2.5 s/message the seven pairs need
# ~70 s after present.
vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --via-virtio \
    --script '$RUN_DIR/script-pad.txt' \
    --pointer-virtio '99,382,d;99,382,u;498,187,d;498,187,u;414,187,d;414,187,u;78,237,d;78,237,u;330,387,d;330,387,u;498,187,d;498,187,u;498,337,d;498,337,u' \
    --pointer-virtio-after 'gocalc: present' \
    --script3 '$RUN_DIR/script3-pad.txt' \
    --script3-after 'gocalc: result FE&0F=E' \
    --script-expect 'rx-gocalc-pad-ok' --timeout 300

vgate_assert 04 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 04 serial-contains 'gocalc: open id='
# `declare refused` is load-bearing: it pins the bare-shim path where the
# kernel itself delivers MOUSE_* — under a seat this run could never
# reach the pad.
vgate_assert 04 serial-contains 'gocalc: declare refused'
vgate_assert 04 serial-contains 'gocalc: present'
vgate_assert 04 serial-contains 'gocalc: result FE&0F=E'
vgate_assert 04 serial-contains 'rx-gocalc-pad-ok'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

vgate_assert 04 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "CALC", "RESULT.TXT")
want = b"FE&0F=E\n"
got = open(path, "rb").read()
if got != want:
    print("RESULT CONTENT MISMATCH: got %r want %r" % (got, want))
    raise SystemExit(1)
print("result verified on the host: %r (%d bytes)" % (got, len(got)))
PY
# --- run 05 (M104h / #2275): the migrated chrome, as PIXELS ---------------
# Same bare-shim boot as run 04: `declare` refused, native 512x384 window
# at (32,32), so the app's bound surface is blitted 1:1 at the declared
# rect and the kernel's 16px title band covers canvas rows 0..15. '1,2,+,3'
# lands after the first present; script3's echo at +20 s is the snapshot
# trigger, so the kind-4 stream reads a fully settled frame — the same
# marker-settle idiom as the seat specs. No '=': the run ends with the
# app still open (RESULT.TXT is run 01-04's evidence, not this leg's).
vgate_file script3-pixels.txt <<'S3EOF'
echo rx-gocalc-pixels
S3EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-05' \
    --script '$RUN_DIR/script-pad.txt' \
    --input-chords '1,2,+,3' \
    --input-chords-after 'gocalc: present' \
    --script3 '$RUN_DIR/script3-pixels.txt' \
    --script3-after 'gocalc: present' \
    --script3-delay 20 \
    --snapshot-after 'rx-gocalc-pixels' \
    --script-expect 'rx-gocalc-pixels' --timeout 300

vgate_assert 05 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 05 serial-contains 'gocalc: open id='
vgate_assert 05 serial-contains 'gocalc: declare refused'
vgate_assert 05 serial-contains 'gocalc: present'
vgate_assert 05 serial-contains 'rx-gocalc-pixels'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'

# The M104 composite, probed on the raw BGRX scanout. Window-local coords
# are canvas coords: the app surface is blitted 1:1 at (32,32). Decimal pad
# is 5x4, btn 118x52, PadMD=8, pad top y0=84:
#   "C" plate canvas (8,84,118,52) -> scanout x 40..157, y 116..167
#   "7" plate canvas (8,144,118,52) -> scanout x 40..157, y 176..227
#   display canvas (8,32,496,44) -> scanout x 40..535, y 64..107
# The discriminating probe is the corner: the v2 full-canvas path paints
# FillRoundedRect + StrokeRoundedRect, so each plate's OUTER corner pixel
# keeps the window Bg the app filled first; the v1 RectCanvas path filled
# the whole outer rect with Border, and would read 0x334155 there.
vgate_assert 05 snapshot 'snap-05-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))

def px(x, y):
    off = (y * W + x) * 4
    b, g, r = raw[off], raw[off + 1], raw[off + 2]
    return (r, g, b)

BG       = (0x18, 0x20, 0x26)  # theme.Dark.Bg - the window fill (tabapp.FillRGB)
SURFACE  = (0x22, 0x2d, 0x35)  # display/history plate
BORDER   = (0x33, 0x41, 0x55)  # §2.2 plate stroke
BTNIDLE  = (0x2d, 0x37, 0x48)  # §2.3 idle face
TEXT     = (0xff, 0xff, 0xff)  # button label ink
INK      = (0xe6, 0xed, 0xf3)  # display text ink
TITLE    = (0x1a, 0x2b, 0x3c)  # kernel title band (user_title_bg dark)

# Kernel chrome band over canvas rows 0..15 -> scanout rows 32..47: the
# window's own chrome frame is present and the surface sits below it.
band = [px(x, y) for y in range(34, 46) for x in range(60, 530, 10)]
if sum(1 for c in band if c == TITLE) * 2 < len(band):
    sys.exit("title band rows are not the kernel chrome colour")

# The "C" plate's OUTER corner is the v2/v1 discriminator: rounded plates
# leave it at the window Bg the app's FillRect painted first.
c = px(40, 116)
if c == BORDER:
    sys.exit("plate outer corner is Border - the flat RectCanvas v1 path "
             "painted, not the rounded §2.2 plate")
if c != BG:
    sys.exit("plate outer corner is %r, want window Bg %r" % (c, BG))
# The stroke rides the plate edge, the face fills inside it.
assert px(99, 116) == BORDER, \
    "plate top edge %r is not the Border stroke" % (px(99, 116),)
assert px(40, 141) == BORDER, \
    "plate left edge %r is not the Border stroke" % (px(40, 141),)
assert px(70, 130) == BTNIDLE and px(99, 160) == BTNIDLE, \
    "plate interior is not BtnIdle: %r %r" % (px(70, 130), px(99, 160))

# The gap between the display's bottom (canvas 76) and the pad top (84)
# is the window fill - proof the app, not the kernel, painted this field.
assert px(300, 112) == BG, "pad/display gap %r is not window Bg" % (px(300, 112),)

# The '7' label: the kit's 8x8 bitmap face in Text ink. Nil-face labels
# are LEFT-anchored (drawGlyphRun: plate inset 2, vertically centred), so
# the glyph box is canvas x 11..18, y 166..173 -> scanout x 43..50,
# y 198..205 - a live counterpart to the composite golden's degrade-path
# labels.
glyph = sum(1 for y in range(198, 206) for x in range(43, 51)
            if px(x, y) == TEXT)
if glyph < 4:
    sys.exit("only %d Text px in the '7' label zone - the bitmap label "
             "did not paint" % glyph)

# '12+3' in the display: Ink digits over the Surface plate.
digits = sum(1 for y in range(64, 108) for x in range(40, 536)
             if px(x, y) == INK)
if digits < 12:
    sys.exit("only %d Ink px in the display band - '12+3' did not repaint" % digits)

# Outside the window is NOT the app: the wallpaper gradient, which shares
# no token with the pad field.
out = px(700, 300)
if out in (BG, SURFACE, BORDER, BTNIDLE, TEXT, INK, TITLE):
    sys.exit("outside-window pixel %r collides with an app token - the "
             "window may not be where the probes assume" % (out,))
print("calc chrome: corner=Bg, border+BtnIdle plates, '7' label %d px, "
      "display %d Ink px, title band ok" % (glyph, digits))
PY

# --- run 06 (M192c / #3248): the state leg under GOTABWM ---------------------
# go-sheet run-06's boot shape: a clean session (no stale SESSION.TABS, no
# leftover demo countdown), the Go seat, `dui focus 0` then the app. The
# chord run puts the calc in programmer mode, evaluates one entry so the
# tape holds 'HEX FF-1=FE', runs the copy verb — refused under uid_user
# (CAP_CLIPBOARD/seat-only; the honest refusal rides the marker — then
# closes the tab and reopens it. The seat collects the envelope on close
# and hands it back to the re-exec'd process.
vgate_file script-06.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-06.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
EOF

vgate_file script3-06.txt <<'EOF'
echo rx-gocalc-state-ok
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio \
    --script '$RUN_DIR/script-06.txt' \
    --script2 '$RUN_DIR/script2-06.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'p,f,f,-,1,return,t,ctrl-shift-w,ctrl-shift-t' \
    --input-chords-after 'gocalc: present' \
    --script3 '$RUN_DIR/script3-06.txt' \
    --script3-after 'gocalc: state restored ' \
    --script-expect 'rx-gocalc-state-ok' --timeout 300

vgate_assert 06 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 06 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 06 serial-contains 'gocalc: declare accepted'
vgate_assert 06 serial-contains 'gocalc: present'
vgate_assert 06 serial-contains 'gocalc: result FF-1=FE'
# The copy verb under a plain seat launch: the named refusal, not silence.
vgate_assert 06 serial-contains 'gocalc: tape copy refused rc='
# The seat's ask, the app's appver-1 answer, the close, the reopen.
vgate_assert 06 serial-contains 'gotabwm: state ask id='
vgate_assert 06 serial-contains 'gocalc: state saved n='
vgate_assert 06 serial-contains 'gotabwm: state save id='
vgate_assert 06 serial-contains 'gotabwm: tab close id='
vgate_assert 06 serial-contains 'gotabwm: reopen GOCALC.ELF'
vgate_assert 06 serial-contains 'gotabwm: state restore id='
# Byte-for-byte: the marker names mode AND the tape's surviving entry.
vgate_assert 06 serial-contains 'gocalc: state restored mode=prog tape=1 last=HEX FF-1=FE'
vgate_assert 06 serial-contains 'rx-gocalc-state-ok'
vgate_assert 06 serial-absent 'gocalc: state refused'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'

# --- run 07 (M192c / #3248): the copy verb lands on the typed clipboard ------
# `exec -u0` is the capable path (the go-sheet clipboard-leg convention):
# a uid_user app gets EACCES from slot 38 by design, so run 06 pins the
# refusal and this run pins the landing. 't' publishes the tape as
# text/plain; the monitor's `clip` reads the kernel buffer back verbatim.
vgate_file script-07.txt <<'EOF'
exec -u0 GOCALC.ELF
EOF

vgate_file script3-07.txt <<'EOF'
clip
echo rx-gocalc-copy-ok
EOF

vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --via-virtio \
    --script '$RUN_DIR/script-07.txt' \
    --input-chords 'p,f,f,-,1,return,t' \
    --input-chords-after 'gocalc: present' \
    --script3 '$RUN_DIR/script3-07.txt' \
    --script3-after 'gocalc: tape copy n=' \
    --script-expect 'rx-gocalc-copy-ok' --timeout 240

vgate_assert 07 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 07 serial-contains 'gocalc: present'
vgate_assert 07 serial-contains 'gocalc: result FF-1=FE'
vgate_assert 07 serial-contains 'gocalc: tape copy n=11'
# The load-bearing assert: the kernel buffer reads back the tape bytes.
vgate_assert 07 serial-contains 'clip: HEX FF-1=FE'
vgate_assert 07 serial-contains 'rx-gocalc-copy-ok'
vgate_assert 07 serial-absent 'gocalc: tape copy refused'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'exited status=139'
