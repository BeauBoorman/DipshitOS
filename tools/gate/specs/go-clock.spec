# go-clock.spec -- GOCLOCK.ELF (M144a, #2794) class-B gate: the four-tab
# clock app (World / Stopwatch / Timer / Alarm) hosted by the live Go
# seat, with every app deadline multiplexed onto the process's ONE kernel
# app timer (sys_timer_set / EvTimer kind 9, kernel/src/app_timers.zig).
#
# user/go/goclock is a tabapp client: init -> declare (kind-8 WM_RPC) ->
# present -> accept injected keystrokes. Its scheduler (sched.go) arms the
# kernel timer for the earliest pending deadline and fans each TIMER event
# out to every due entry; a fired user deadline raises a seat toast
# (vi.Notify, WM_RPC kind 12) and prints `goclock: fired <id>`.
#
# Legs:
#   run 01  the World tab as PIXELS. The seat hosts the app fullscreen —
#           its surface is composited at scanout (0,0) under the 22px
#           rail, so canvas coords ARE scanout coords. The app prints
#           `goclock: painted epoch=<n>` once per presented frame; the
#           probe takes the last marker's epoch, computes each row's
#           string on the HOST (python's own gmtime for epoch+offset, the
#           label re-canonicalized from the app-claimed zone), and
#           glyph-decodes the scanout's 8x8 cells against the same
#           font8x8 table the widget kit paints with — two zones must
#           render the same instant at their own offsets.
#   run 02  the countdown -> toast -> click-through chain. Chords switch
#           to the Timer tab and arm a 3-second timer; `dui cycle` blurs
#           the app so the focus change is real; the seat paints the
#           toast (slot 0 of notifyRect(1280,720,0,1) = (8,692,208,20),
#           centre 112,702); the pointer press on it dismisses the toast
#           and focuses GOCLOCK's tab — dismiss/focus markers bound to
#           the sender id the `notify id=` line named.
#   run 03  the stopwatch + alarm surface: the watch ticks via the same
#           multiplexed timer (start/stop/reset markers), and a 4-digit
#           HHMM entry arms the daily alarm (`goclock: alarm armed
#           HH:MM`), then cancels.
#
# HOST PREREQUISITES (the gate fails honestly when missing):
#   bash tools/go/build-goclock.sh  ->  .build/go/GOCLOCK.ELF
#   bash tools/go/build-gotabwm.sh  ->  .build/go/GOTABWM.ELF
#
# exec-order: assert-proven -- each run ends on a marker only its own
# stage chain can produce.

vgate_name go-clock "issue #2794 M144a: GOCLOCK.ELF — world clock, stopwatch, timer, alarm->toast over one multiplexed kernel timer"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for name, how in (("GOCLOCK", "build-goclock.sh"),
                  ("GOTABWM", "build-gotabwm.sh")):
    src = os.path.join(".build", "go", name + ".ELF")
    if not os.path.exists(src):
        sys.exit(name + ".ELF missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name + ".ELF"))
    print("staged %s.ELF into share (%d bytes)" %
          (name, os.path.getsize(os.path.join(share, name + ".ELF"))))
PY

# --- run 01: the World face, as pixels ------------------------------------
# Boot, seat autostarts (wm=gotabwm default), exec the app, let it paint a
# few seconds of frames, snapshot, then end on the marker script3 prints.
vgate_file script-01.txt <<'EOF'
echo rx-goclock-01-boot
EOF

vgate_file script2-01.txt <<'EOF'
exec GOCLOCK.ELF
EOF

vgate_file script3-01.txt <<'EOF'
vf rm SESSION.TABS
echo rx-goclock-face
EOF

vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script-01.txt' \
    --script2 '$RUN_DIR/script2-01.txt' \
    --script2-after 'gotabwm: mode live' \
    --script3 '$RUN_DIR/script3-01.txt' \
    --script3-after 'goclock: painted epoch=' \
    --script3-delay 6 \
    --snapshot-after 'rx-goclock-face' \
    --script-expect 'rx-goclock-face' --timeout 300

vgate_assert 01 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 01 serial-contains 'gotabwm: mode live'
vgate_assert 01 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 01 serial-contains 'goclock: open id='
vgate_assert 01 serial-contains 'goclock: declare accepted'
vgate_assert 01 serial-contains 'goclock: zones local=UTC n='
vgate_assert 01 serial-contains 'goclock: present'
vgate_assert 01 serial-contains 'goclock: ktimer armed'
vgate_assert 01 serial-contains 'goclock: painted epoch='
vgate_assert 01 serial-contains 'rx-goclock-face'
vgate_assert 01 serial-absent 'goclock: ktimer arm failed'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The pixel probe. Geometry (pinned by user/go/goclock/main.go's layout
# and widgets.drawGlyphRun): row i's plate is (16, 56+i*20, 608, 18); the
# bitmap run lives in plate.Inset(2) so glyph cell j occupies
#   x = 18+j*8 .. 26+j*8,  y = 61+i*20 .. 69+i*20   (canvas == scanout px).
# Each row's string is clockfmt.Format: 'YYYY-MM-DD HH:MM:SS UTC±HH:MM'
# (29 chars). The host recomputes the string from the app's epoch marker
# (plus a small lag window — the seat composites on its own ~1s tick, so
# the snapshotted frame can trail the marker) and requires a glyph-exact
# match on at least TWO rows: the settings row (UTC on a default share)
# and a fixed-offset row.
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import os, re, sys, time

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

def lum(p):
    return p[0] * 0.30 + p[1] * 0.55 + p[2] * 0.15

# The 8x8 face — lifted from the same source the widget kit links
# (user/go/webrender/font/font8x8.go): 95 glyphs, 8 rows of 1 byte,
# bit 0 the leftmost pixel.
src = open("user/go/webrender/font/font8x8.go").read()
rows = re.findall(r"\{(0x[0-9a-fA-F]{2}(?:,\s*0x[0-9a-fA-F]{2}){7})\}", src)
if len(rows) != 95:
    sys.exit("font8x8.go: %d glyph rows, want 95" % len(rows))
GB = {}
for i, r in enumerate(rows):
    vals = [int(v, 16) for v in r.split(",") if v.strip()]
    mask = 0
    for y in range(8):
        for x in range(8):
            mask = (mask << 1) | ((vals[y] >> x) & 1)
    GB[0x20 + i] = mask

# Snapshot asserts run without VG_SER; the run's serial log sits in the same
# RUN_DIR as the snap file (vm-serial-<tag>.log, tag taken from snap name).
tag = re.match(r"snap-(\w+)-\d+\.raw", os.path.basename(sys.argv[1]))
if not tag:
    sys.exit("unexpected snap name %r" % os.path.basename(sys.argv[1]))
ser_path = os.path.join(os.path.dirname(sys.argv[1]),
                        "vm-serial-%s.log" % tag.group(1))
ser = open(ser_path, errors="replace").read()

mz = re.search(r"(?m)^goclock: zones local=(\S+) n=(\d+)$", ser)
if not mz:
    sys.exit("no 'goclock: zones' marker in serial")
local_label, nrows = mz.group(1), int(mz.group(2))
zone_marks = dict(
    (int(m.group(1)), m.group(2))
    for m in re.finditer(r"(?m)^goclock: zone (\d+) (\S+)$", ser))
if len(zone_marks) != nrows:
    sys.exit("zone markers: %d rows, want %d" % (len(zone_marks), nrows))

me = list(re.finditer(r"(?m)^goclock: painted epoch=(\d+)$", ser))
if not me:
    sys.exit("no painted-epoch markers in serial")
epoch = int(me[-1].group(1))

def label_to_off(lab):
    if lab == "UTC":
        return 0
    m = re.fullmatch(r"UTC([+-])(\d{2}):(\d{2})", lab)
    if not m:
        sys.exit("zone label %r is not the canonical shape" % lab)
    off = int(m.group(2)) * 3600 + int(m.group(3)) * 60
    return -off if m.group(1) == "-" else off

def expected(epoch, off, lab):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(epoch + off)) + " " + lab

def decode_cell(x0, y0):
    lums = [lum(px(x0 + k % 8, y0 + k // 8)) for k in range(64)]
    lo, hi = min(lums), max(lums)
    if hi - lo < 20:
        return " "
    mid = (lo + hi) / 2
    mask = 0
    for v in lums:
        mask = (mask << 1) | (v >= mid)
    best, bs = 32, 999
    for cp, gm in GB.items():
        d = bin(mask ^ gm).count("1")
        if d < bs:
            bs, best = d, cp
    return chr(best)

def decode_row(i, nchars=29):
    y0 = 61 + i * 20
    return "".join(decode_cell(18 + j * 8, y0) for j in range(nchars))

# Candidates: the last painted epoch and the few seconds before it (the
# seat's composite tick can lag the marker).
cand = [epoch - d for d in range(0, 4)]
decoded = {}
matched = 0
fails = []
for i in range(nrows):
    lab = zone_marks[i]
    off = label_to_off(lab)
    text = decode_row(i)
    decoded[i] = text
    if any(text == expected(e, off, lab) for e in cand):
        matched += 1
    else:
        fails.append("row %d (%s): got %r" % (i, lab, text))
if matched < 2:
    sys.exit("fewer than two zone rows render host-computed strings "
             "(epoch %d, window %s):\n%s" %
             (epoch, cand, "\n".join(fails[:6])))
print("world face: %d/%d rows glyph-exact at epoch ~%d; row0=%r row1=%r"
      % (matched, nrows, epoch, decoded.get(0), decoded.get(1)))
PY

# --- run 02: countdown -> seat toast -> click-through ---------------------
# Arm a 3-second timer on the Timer tab, blur the app with dui cycle so the
# click's focus change is a real transition, then press the painted toast.
# The click gates on `timer done` — the app's own `notify id=` line: it is
# printed after the toast is already queued (hit-test scans the queue, not
# the pixels), and unlike `notify paint id=` it can never match a seat-side
# toast that predates the app. Run 01's `vf rm SESSION.TABS` keeps the
# session-restore refusal toast out of runs 02/03 entirely.
vgate_file script-02.txt <<'EOF'
echo rx-goclock-02-boot
EOF

vgate_file script2-02.txt <<'EOF'
exec GOCLOCK.ELF
EOF

vgate_file script3-02.txt <<'EOF'
dui cycle
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-02' \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: mode live' \
    --input-chords 'right,right,3,return' \
    --input-chords-after 'goclock: painted epoch=' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'goclock: timer armed 3' \
    --pointer-virtio '112,702,d;112,702,u' \
    --pointer-virtio-after 'timer done' \
    --script-expect 'gotabwm: notify dismiss id=' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 02 serial-contains 'goclock: declare accepted'
vgate_assert 02 serial-contains 'goclock: tab timer'
vgate_assert 02 serial-contains 'goclock: timer armed 3'
# The blur: focus left the app before the deadline fired.
vgate_assert 02 serial-contains 'dui: cycle focused='
# The fire chain, in order: deadline fired -> marker + notify request ->
# seat queued -> toast painted -> click dismissed -> sender focused.
vgate_assert 02 serial-contains 'goclock: fired timer'
# A one-shot deadline fires exactly once — the multiplexer must not
# re-arm it.
vgate_assert 02 serial-exact 'goclock: fired timer' 1
vgate_assert 02 serial-absent 'goclock: notify refused timer'
vgate_assert 02 serial-contains 'gotabwm: notify id='
vgate_assert 02 serial-contains 'timer done'
vgate_assert 02 serial-contains 'gotabwm: notify paint id='
vgate_assert 02 serial-contains 'gotabwm: notify dismiss id='
vgate_assert 02 serial-contains 'gotabwm: tab focus id='
vgate_assert 02 serial-contains 'gotabwm: host focus id='
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# The chain as an ordering + identity check: the fire precedes the queue,
# the queue precedes the paint, the paint precedes the dismiss, and the
# dismiss + focus markers name the same window id the queue line carried —
# the toast belonged to GOCLOCK and the click focused exactly it.
#
# The adoption pair is the trap: a fresh declare's taskbar-click prints
# `gotabwm: host focus id=` AND `gotabwm: tab focus id=` at exec time —
# long before the timer fires — so the focus legs of this chain are the
# FIRST occurrences AFTER the dismiss, not the first occurrences overall.
# (The same reason `--script-expect` ends on the dismiss marker, never on
# a focus one: a focus marker at adoption would stop the VM while the
# armed timer was still counting.)
vgate_assert 02 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def at(pat, what, start=0):
    m = re.compile(pat).search(ser, start)
    if not m:
        sys.exit("no %s in the serial log" % what)
    return m

armed   = at(r"(?m)^goclock: timer armed 3$", "arm marker")
blurred = at(r"(?m)^dui: cycle focused=(\d+)$", "blur marker")
fired   = at(r"(?m)^goclock: fired timer$", "fire marker")
queued  = at(r"(?m)^gotabwm: notify id=(\d+) timer done$", "seat queue line")
painted = at(r"(?m)^gotabwm: notify paint id=(\d+)$", "toast paint")
dismiss = at(r"(?m)^gotabwm: notify dismiss id=(\d+)$", "toast dismiss", painted.end())
tabfoc  = at(r"(?m)^gotabwm: tab focus id=(\d+)$", "tab focus", dismiss.end())
hostfoc = at(r"(?m)^gotabwm: host focus id=(\d+)$", "host focus", dismiss.end())

if not (armed.start() < blurred.start() < fired.start() < queued.start()
        < painted.start() < dismiss.start() < tabfoc.start() <= hostfoc.start()):
    sys.exit("chain out of order: armed=%d blur=%d fired=%d queued=%d "
             "painted=%d dismiss=%d tabfoc=%d hostfoc=%d"
             % (armed.start(), blurred.start(), fired.start(), queued.start(),
                painted.start(), dismiss.start(), tabfoc.start(), hostfoc.start()))

wid = queued.group(1)
for name, m in (("paint", painted), ("dismiss", dismiss),
                ("tab focus", tabfoc), ("host focus", hostfoc)):
    if m.group(1) != wid:
        sys.exit("the %s marker names id=%s, want the sender id=%s"
                 % (name, m.group(1), wid))
print("toast chain OK: timer armed -> blurred -> fired -> toast id=%s "
      "painted -> clicked -> goclock focused" % wid)
PY

# --- run 03: stopwatch + alarm surface ------------------------------------
# The same multiplexed timer drives the watch's 1 Hz face; the alarm arm
# is the sched.Add that takes HHMM -> next civil occurrence, daily repeat.
vgate_file script-03.txt <<'EOF'
echo rx-goclock-03-boot
EOF

vgate_file script2-03.txt <<'EOF'
exec GOCLOCK.ELF
EOF

vgate_file script3-03.txt <<'EOF'
echo rx-goclock-ok
EOF

# 'q' is the app's own quit key (Escape is not a gate chord); the run ends
# on the rx marker after goclock's clean-exit pair prints.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio \
    --script '$RUN_DIR/script-03.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'gotabwm: mode live' \
    --input-chords 'right,s,right,right,2,3,5,9,return,q' \
    --input-chords-after 'goclock: painted epoch=' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'goclock OK' \
    --script-expect 'rx-goclock-ok' --timeout 300

vgate_assert 03 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 03 serial-contains 'goclock: tab stopwatch'
vgate_assert 03 serial-contains 'goclock: stopwatch start'
vgate_assert 03 serial-contains 'goclock: tab timer'
vgate_assert 03 serial-contains 'goclock: tab alarm'
vgate_assert 03 serial-contains 'goclock: alarm armed 23:59'
vgate_assert 03 serial-contains 'goclock: close'
vgate_assert 03 serial-contains 'goclock OK'
vgate_assert 03 serial-contains 'rx-goclock-ok'
vgate_assert 03 serial-absent 'goclock: deadline full'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
