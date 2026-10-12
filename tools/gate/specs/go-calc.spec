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
#
# The load-bearing evidence is NOT only the app's own markers: each run's
# last assert reads the share file back ON THE HOST and requires it to
# equal the typed expression plus the result, so a stub that printed
# success without doing the arithmetic cannot pass.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gocalc.sh   ->  .build/go/GOCALC.ELF
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
