# go-clock.spec -- GOCLOCK.ELF (M144a #2794 + M144b #2795 + M152b #2916)
# class-B gate: the four-tab clock app (World / Stopwatch / Timer / Alarm)
# hosted by the live Go seat, with every app deadline multiplexed onto the
# process's ONE kernel app timer (sys_timer_set / EvTimer kind 9,
# kernel/src/app_timers.zig), and the alarm list persisting through the
# seat's save_state blob and its own crash-safe share file.
#
# user/go/goclock is a tabapp client: init -> declare (kind-8 WM_RPC) ->
# present -> accept injected keystrokes. Its scheduler (sched.go) arms the
# kernel timer for the earliest pending deadline and fans each TIMER event
# out to every due entry; a fired user deadline raises a seat toast
# (vi.Notify, WM_RPC kind 12) and prints `goclock: fired <id>` (alarm
# deadline ids are the row index: alarm0..alarm6).
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
#   run 04  M144b save half: chords arm 23:59 — the app publishes
#           `gocal1 <at> <hhmm>` crash-safe to /host/GOCLOCK.ALARM
#           (`goclock: alarm saved`) and pushes the same record through
#           save_state (`state posted`); the ctrl-shift-s chord then asks
#           every bound tab, stores the blob in SESSION.TABS's AS trailer
#           and publishes SNAPSHOT.BUNDLE (`gotabwm: snapshot saved`).
#   run 05  M144b restore half: a fresh boot's session load mode=restore
#           re-execs GOCLOCK — restore_state hands the blob back
#           (`state restored`, `alarm restored 23:59`); then a `time sync`
#           inside serial-attached GOSH steps the wall clock +90000 s
#           (--net-sntp-skew) and the armed deadline, now long due, fires
#           exactly once on the next face tick — "came due while the
#           machine was suspended", observed live. The typed sync waits
#           --script2-delay 10 past `gosh: attached`: the `net arp` reply
#           is learned asynchronously by the RX drain, and under vgate_repeat
#           contention the request occasionally lands before the learn —
#           `time sync` then reports `no route` and the leg times out.
#   run 06  M144b reboot leg: a hand-staged stale record (`write
#           GOCLOCK.ALARM gocal1 1 2359`, the monitor's own share write)
#           re-arms from the file at exec and the overdue deadline fires
#           once at start, marked late (`goclock: fired alarm0 late`) —
#           also the gocal1-still-reads leg.
#   run 07  M152b arm leg: chords add a daily 06:45 and a once 19:20 row
#           on the Alarm tab, preset key '1' arms the 60 s countdown on
#           the Timer tab (`goclock: timer armed 60` -> `goclock: fired
#           timer`), and ctrl-shift-s snapshots the gocal2 list into
#           SESSION.TABS + the share file.
#   run 08  M152b restore leg: a fresh boot's session restore re-execs
#           GOCLOCK — both rows come back (`goclock: alarm restored
#           HH:MM daily|once`), the daily one armed to ring again. Tail
#           cleanup leaves the share empty for the next iteration.
#
# HOST PREREQUISITES (the gate fails honestly when missing):
#   bash tools/go/build-goclock.sh  ->  .build/go/GOCLOCK.ELF
#   bash tools/go/build-gotabwm.sh  ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gosh.sh     ->  .build/go/GOSH.ELF (run 05)
#
# exec-order: assert-proven -- each run ends on a marker only its own
# stage chain can produce.

vgate_name go-clock "issue #2794 M144a + #2795 M144b + #2916 M152b: GOCLOCK.ELF — world clock, stopwatch, timer, alarm->toast over one multiplexed kernel timer; the gocal2 alarm list (up to 7, once/daily, toggled) persists through save_state + its own share file, gocal1 still reads, late-fire on start"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for name, how in (("GOCLOCK", "build-goclock.sh"),
                  ("GOTABWM", "build-gotabwm.sh"),
                  ("GOSH", "build-gosh.sh")):
    src = os.path.join(".build", "go", name + ".ELF")
    if not os.path.exists(src):
        sys.exit(name + ".ELF missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name + ".ELF"))
    print("staged %s.ELF into share (%d bytes)" %
          (name, os.path.getsize(os.path.join(share, name + ".ELF"))))
# Run 05's typed line is raw console bytes — CR submits the line in GOSH's
# editor — so it is written here rather than as a heredoc (go-net-clis).
with open(os.path.join(os.environ["RUN_DIR"], "typed-sync-05.bin"), "wb") as f:
    f.write(b"time sync 10.0.0.2\r")
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
    --script3-delay 10 \
    --snapshot-after 'goclock: painted epoch=' \
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
#
# #2795: the kind-4 snap request reads a live scanout while the seat's
# composite tick runs on its own cadence — under vgate_repeat an iteration
# occasionally captures a pre-surface frame (observed: seat chrome present,
# the shared-surface region still background). The spec therefore fires two
# spaced triggers — the first painted marker and the terminal marker — and
# the probe accepts ANY captured frame that reads back a world face, while
# still failing closed when no capture carries the app's pixels.
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import os, re, sys, time, glob as _glob

W, H = 1280, 720
need = W * H * 4
snaps = sorted(_glob.glob(os.path.join(os.path.dirname(sys.argv[1]),
                                       "snap-%s-*.raw"
                                       % re.match(r"snap-(\w+)-\d+\.raw",
                                                  os.path.basename(sys.argv[1])).group(1))),
               key=os.path.getmtime)
frames = []
for p in snaps:
    raw = open(p, "rb").read()
    if len(raw) >= need:
        frames.append((os.path.basename(p), raw))
if not frames:
    sys.exit("no complete snapshot in %s" % snaps)

# The 8x8 face — lifted from the same source the widget kit links
# (user/go/webrender/font/font8x8.go): 95 glyphs, 8 rows of 1 byte,
# bit 0 the leftmost pixel.
def px(raw, x, y):
    off = (y * W + x) * 4
    b, g, r = raw[off], raw[off + 1], raw[off + 2]
    return (r, g, b)

def lum(p):
    return p[0] * 0.30 + p[1] * 0.55 + p[2] * 0.15

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
# The snapshot-out base is the spec's static `snap-01` while the serial
# carries the repeat suffix (vm-serial-01-02.log) — resolve by newest
# match rather than the derived literal so the leg is vgate_repeat-safe.
import glob as _glob
ser_hits = sorted(
    _glob.glob(os.path.join(os.path.dirname(sys.argv[1]),
                            "vm-serial-%s*.log" % tag.group(1))),
    key=os.path.getmtime)
if not ser_hits:
    sys.exit("no serial log for snap tag %s" % tag.group(1))
ser = open(ser_hits[-1], errors="replace").read()

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

def decode_cell(raw, x0, y0):
    lums = [lum(px(raw, x0 + k % 8, y0 + k // 8)) for k in range(64)]
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

def decode_row(raw, i, nchars=29):
    y0 = 61 + i * 20
    return "".join(decode_cell(raw, 18 + j * 8, y0) for j in range(nchars))

# Candidates: the last painted epoch and the few seconds before it (the
# seat's composite tick can lag the marker). Wider than the dep leg's
# original window — the first capture can precede the last paints.
cand = [epoch - d for d in range(0, 10)]
def expected_at(text, i):
    lab = zone_marks[i]
    off = label_to_off(lab)
    return any(text == expected(e, off, lab) for e in cand)

best_match, best_name, best_decoded, best_fails = 0, None, {}, []
for name, raw in frames:
    decoded = {}
    matched = 0
    fails = []
    for i in range(nrows):
        text = decode_row(raw, i)
        decoded[i] = text
        if expected_at(text, i):
            matched += 1
        else:
            fails.append("row %d (%s): got %r" % (i, zone_marks[i], text))
    # Fallback (#2795): under the pane/space seat an iteration can
    # composite the window somewhere other than the declared full-viewport
    # origin (observed 01-01/01-02 K=3: the face lands shifted or the
    # captured frame is a mid-relayout composite). The pixels are still
    # the app's — scan a coarse origin grid for the row pattern and keep
    # the same glyph-exact bar; a frame with no face still fails.
    if matched < 2:
        found = set()
        for y0 in range(0, 712, 2):
            for x0 in range(0, 1040, 4):
                if decode_cell(raw, x0, y0) != "2":
                    continue
                if "".join(decode_cell(raw, x0 + j * 8, y0)
                           for j in range(1, 5)) != "026-":
                    continue
                row = "".join(decode_cell(raw, x0 + j * 8, y0)
                              for j in range(29))
                for i in range(nrows):
                    if expected_at(row, i):
                        found.add((x0, y0 // 20, i))
        matched = max(matched, len(found))
        if found:
            fails = ["face found at offsets %s" % sorted(found)[:6]]
    if matched > best_match:
        best_match, best_name, best_decoded, best_fails = matched, name, decoded, fails
if best_match < 2:
    sys.exit("fewer than two zone rows render host-computed strings "
             "across %d captures (epoch %d, window %s; best %s):\n%s" %
             (len(frames), epoch, cand, best_name, "\n".join(best_fails[:6])))
print("world face: %d/%d rows glyph-exact at epoch ~%d (%s); row0=%r row1=%r"
      % (best_match, nrows, epoch, best_name,
         best_decoded.get(0), best_decoded.get(1)))
PY

# --- run 02: countdown -> seat toast -> click-through ---------------------
# Arm a 3-second timer on the Timer tab ('e' opens the custom-seconds
# entry — a bare '3' would arm the 3-minute preset), blur the app with
# dui cycle so the click's focus change is a real transition, then press
# the painted toast.
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
    --input-chords 'right,right,e,3,return' \
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

# The rm runs after 'x'/'q' have settled: run 02's tab row survives its
# unclosed VM stop, and the cancelled app leaves its own rows empty — the
# rm makes run 04's boot a n=0 session so its arm is the only instance.
vgate_file script3-03.txt <<'EOF'
vf rm SESSION.TABS
echo rx-goclock-ok
EOF

# 'q' is the app's own quit key (Escape is not a gate chord); the run ends
# on the rx marker after goclock's clean-exit pair prints. 'x' deletes the
# picked alarm row first — with M144b persistence an armed-at-exit alarm
# would leak a GOCLOCK.ALARM file and an armed state blob into run 04's
# boot.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio \
    --script '$RUN_DIR/script-03.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'gotabwm: mode live' \
    --input-chords 'right,s,right,right,2,3,5,9,return,x,q' \
    --input-chords-after 'goclock: painted epoch=' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'goclock OK' \
    --script-expect 'rx-goclock-ok' --timeout 300

vgate_assert 03 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 03 serial-contains 'goclock: tab stopwatch'
vgate_assert 03 serial-contains 'goclock: stopwatch start'
vgate_assert 03 serial-contains 'goclock: tab timer'
vgate_assert 03 serial-contains 'goclock: tab alarm'
vgate_assert 03 serial-contains 'goclock: alarm armed 23:59 daily'
vgate_assert 03 serial-contains 'goclock: alarm deleted 23:59'
vgate_assert 03 serial-contains 'goclock: close'
vgate_assert 03 serial-contains 'goclock OK'
vgate_assert 03 serial-contains 'rx-goclock-ok'
vgate_assert 03 serial-absent 'goclock: deadline full'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# --- run 04 (M144b): arm -> file + blob -> snapshot chord ------------------
# Chords switch to the Alarm tab and arm 23:59: the app publishes
# `gocal1 <at> 2359` crash-safe to /host/GOCLOCK.ALARM and pushes the same
# record through save_state. ctrl-shift-s then asks every bound tab and
# captures the bundle — SESSION.TABS's AS trailer carries the blob.
vgate_file script-04.txt <<'EOF'
echo rx-goclock-04-boot
EOF

vgate_file script2-04.txt <<'EOF'
exec GOCLOCK.ELF
EOF

vgate_file script3-04.txt <<'EOF'
ps
smp
echo rx-goclock-saved
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --via-virtio \
    --script '$RUN_DIR/script-04.txt' \
    --script2 '$RUN_DIR/script2-04.txt' \
    --script2-after 'gotabwm: mode live' \
    --input-chords 'right,right,right,2,3,5,9,return,ctrl-shift-s' \
    --input-chords-after 'goclock: painted epoch=' \
    --script3 '$RUN_DIR/script3-04.txt' \
    --script3-after 'gotabwm: snapshot saved ' \
    --script-expect 'rx-goclock-saved' --timeout 300

vgate_assert 04 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 04 serial-contains 'goclock: declare accepted'
vgate_assert 04 serial-contains 'goclock: tab alarm'
vgate_assert 04 serial-contains 'goclock: alarm armed 23:59 daily'
# The record landed crash-safe on the share...
vgate_assert 04 serial-contains 'goclock: alarm saved'
vgate_assert 04 share-contains 'GOCLOCK.ALARM' 'gocal2 '
vgate_assert 04 share-contains 'GOCLOCK.ALARM' ' 2359 d+'
# ...and the unsolicited push kept the seat's stored blob current.
vgate_assert 04 serial-contains 'goclock: state posted'
# The snapshot chord asked the bound tab, stored its answer on the tab's
# session record, republished the session, and captured the bundle.
vgate_assert 04 serial-contains 'gotabwm: state ask id='
vgate_assert 04 serial-contains 'gotabwm: state save id='
vgate_assert 04 serial-contains ' ver=1'
vgate_assert 04 serial-contains 'gotabwm: snapshot saved '
vgate_assert 04 serial-contains 'rx-goclock-saved'
vgate_assert 04 serial-absent 'gotabwm: state drop'
vgate_assert 04 serial-absent 'goclock: alarm save failed'
vgate_assert 04 serial-absent 'goclock: deadline full'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

# Byte-level on the share (the go-wm-tabs run-12 idiom): the .tabs v2
# trailer framing and the record — exactly one row's blob IS the gocal2
# line, byte identity being the card's claim. The row count is not pinned:
# an earlier leg's unclosed tab can leave a sibling row in the session.
vgate_assert 04 python <<'PY'
import os, re, sys
b = open(os.path.join(os.environ["VG_SHARE"], "SESSION.TABS"), "rb").read()
if b[0] != 2 or b[2] < 1:
    sys.exit("SESSION.TABS header ver=%d count=%d" % (b[0], b[2]))
off = 6 + 69 * b[2]
if len(b) < off + 6 + 8:
    sys.exit("SESSION.TABS too short for a state trailer: %d" % len(b))
if b[off:off+2] != b"AS" or b[off+2] != 1 or b[off+3] < 1:
    sys.exit("app_state header %r" % b[off:off+6])
asc = b[off+3]
pos = off + 6 + 8 * asc
hits = []
for i in range(asc):
    ent = b[off+6+8*i:off+14+8*i]
    ln = int.from_bytes(ent[4:8], "little")
    blob = b[pos:pos+ln]
    pos += ln
    if re.fullmatch(rb"gocal2 1 [0-9]+ 2359 d\+", blob):
        hits.append((ent[0], ent[1], blob))
if len(hits) != 1 or hits[0][1] != 1:
    sys.exit("want exactly one appver=1 gocal2 blob, found %r" % hits)
print("SESSION.TABS app_state: idx=%d appver=%d blob=%r" % hits[0])
PY

# --- run 05 (M144b): reboot -> session restore -> armed -> fires -----------
# A fresh boot's session load re-execs GOCLOCK; restore_state hands the
# blob back and the alarm re-arms (`alarm restored`). Then `time sync`
# inside serial-attached GOSH steps the wall clock 25 hours forward — the
# armed instant is long past — and the next face tick fires it ONCE: the
# daily repeater catches up to the next future occurrence rather than
# re-firing. `fired alarm` late-spellings count too (a sub-minute boundary
# arm is still an honest single fire).
vgate_file script-05.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOSH.ELF serial
EOF

vgate_file script3-05.txt <<'EOF'
echo rx-goclock-restored
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --net '$RUN_DIR/cap-05.bin' --net-arp-respond 10.0.0.2 \
    --net-sntp-respond 10.0.0.2 --net-sntp-skew 90000 \
    --script '$RUN_DIR/script-05.txt' \
    --script2 '$RUN_DIR/typed-sync-05.bin' --script2-after 'gosh: attached' \
    --script2-delay 10 \
    --script3 '$RUN_DIR/script3-05.txt' \
    --script3-after 'goclock: fired alarm' \
    --script-expect 'rx-goclock-restored' --timeout 300

vgate_assert 05 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 05 serial-contains 'gotabwm: mode live'
# n is unpinned — the first-boot workspace's GOSH tab is a second row.
vgate_assert 05 serial-contains 'gotabwm: session load n='
vgate_assert 05 serial-contains ' mode=restore'
vgate_assert 05 serial-contains 'gotabwm: session reexec n='
vgate_assert 05 serial-contains 'gotabwm: session exec GOCLOCK.ELF'
vgate_assert 05 serial-contains 'goclock: declare accepted'
# The stored blob came back through restore_state...
vgate_assert 05 serial-contains 'goclock: state restored'
# ...and the persisted record re-armed the daily alarm.
vgate_assert 05 serial-contains 'goclock: alarm restored 23:59'
vgate_assert 05 serial-contains 'gosh: attached'
vgate_assert 05 serial-contains 'time sync: synced server=10.0.0.2'
vgate_assert 05 serial-contains 'rx-goclock-restored'
vgate_assert 05 serial-absent 'goclock: state refused'
vgate_assert 05 serial-absent 'goclock: alarm file bad'
vgate_assert 05 serial-absent 'goclock: deadline full'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
# Armed AND fires — exactly once: the restored daily alarm fires its
# overdue occurrence and re-arms; it never repeats inside the leg.
vgate_assert 05 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
fires = re.findall(r"^goclock: fired alarm\d+( late)?$", ser, re.M)
n = len(fires)
if n != 1:
    sys.exit("goclock alarm fired %d times after restore, want exactly 1" % n)
restored = re.search(r"^goclock: alarm restored 23:59", ser, re.M)
fired = re.search(r"^goclock: fired alarm\d+( late)?$", ser, re.M)
if not (restored and fired and restored.start() < fired.start()):
    sys.exit("arm/restore must precede the fire")
print("restore leg: alarm restored 23:59, fired once after the clock step")
PY

# --- run 06 (M144b): reboot late-fire --------------------------------------
# The monitor's own share write stages the record the app itself writes —
# `gocal1 1 2359`, due at epoch 1 — so the exec is a reboot landing after
# the armed instant: the file re-arms the alarm and the overdue deadline
# fires once at start, marked late. Run 05's residue may add a second
# session-restored goclock beside the exec'd one — every restoring instance
# fires its catch-up exactly once, so the assert pairs each `alarm
# restored` with exactly one `fired alarm late` and no plain fire. Tail
# cleanup (monitor context — run 06 attaches no gosh) leaves the share
# empty of clock state so the next iteration boots clean.
vgate_file script-06.txt <<'EOF'
write GOCLOCK.ALARM gocal1 1 2359
EOF

vgate_file script2-06.txt <<'EOF'
exec GOCLOCK.ELF
EOF

vgate_file script3-06.txt <<'EOF'
vf rm SESSION.TABS
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
vf rm GOCLOCK.ALARM
echo rx-goclock-late-ok
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio \
    --script '$RUN_DIR/script-06.txt' \
    --script2 '$RUN_DIR/script2-06.txt' \
    --script2-after 'write: ok' \
    --script3 '$RUN_DIR/script3-06.txt' \
    --script3-after 'goclock: fired alarm' \
    --script-expect 'rx-goclock-late-ok' --timeout 300

vgate_assert 06 serial-contains 'write: ok (persisted '
vgate_assert 06 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 06 serial-contains 'goclock: declare accepted'
# Re-armed from the file, then fired once on start — marked late.
vgate_assert 06 serial-contains 'goclock: alarm restored 23:59'
vgate_assert 06 serial-contains 'goclock: fired alarm0 late'
vgate_assert 06 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
if re.search(r"^goclock: fired alarm\d+$", ser, re.M):
    sys.exit("a plain fire printed — the reboot catch-up must be marked late")
restored = re.findall(r"^goclock: alarm restored 23:59", ser, re.M)
late = re.findall(r"^goclock: fired alarm\d+ late$", ser, re.M)
if len(restored) < 1:
    sys.exit("no instance re-armed from the staged record")
if len(late) != len(restored):
    sys.exit("restored=%d late-fires=%d — every catch-up must fire "
             "exactly once" % (len(restored), len(late)))
print("reboot leg: %d instance(s) re-armed 23:59 from the staged record, "
      "each fired once marked late" % len(late))
PY
vgate_assert 06 serial-contains 'rx-goclock-late-ok'
vgate_assert 06 serial-absent 'goclock: alarm file bad'
vgate_assert 06 serial-absent 'goclock: deadline full'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'

# --- run 07 (M152b): two alarms + preset timer -> gocal2 -> snapshot -----
# Chords switch to the Alarm tab and add two rows — 06:45 daily via
# Return, 19:20 once via 'o' — then 'left' reaches the Timer tab and '1'
# arms the 1-minute preset, so `goclock: fired timer` lands inside the
# leg. ctrl-shift-s (same batch — the state ask is answered while the
# countdown runs) snapshots the gocal2 list for run 08's restore boot.
# The alarm times are fixed HHMM fields: an armed row whose instant fell
# inside the leg's own ~4-minute window would fire early, so the asserts
# below only pin the arm markers, never the absence of a fire.
vgate_file script-07.txt <<'EOF'
echo rx-goclock-07-boot
EOF

vgate_file script2-07.txt <<'EOF'
exec GOCLOCK.ELF
EOF

vgate_file script3-07.txt <<'EOF'
echo rx-goclock-v2-armed
EOF

vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --via-virtio \
    --script '$RUN_DIR/script-07.txt' \
    --script2 '$RUN_DIR/script2-07.txt' \
    --script2-after 'gotabwm: mode live' \
    --input-chords 'right,right,right,0,6,4,5,return,1,9,2,0,o,left,1,ctrl-shift-s' \
    --input-chords-after 'goclock: painted epoch=' \
    --script3 '$RUN_DIR/script3-07.txt' \
    --script3-after 'goclock: fired timer' \
    --script-expect 'rx-goclock-v2-armed' --timeout 300

vgate_assert 07 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 07 serial-contains 'goclock: declare accepted'
vgate_assert 07 serial-contains 'goclock: tab alarm'
# Two rows side by side: the daily wake-up and the one-off reminder.
vgate_assert 07 serial-contains 'goclock: alarm armed 06:45 daily'
vgate_assert 07 serial-contains 'goclock: alarm armed 19:20 once'
# Every mutation republished the gocal2 list through both carriers.
vgate_assert 07 serial-contains 'goclock: alarm saved'
vgate_assert 07 serial-contains 'goclock: state posted'
vgate_assert 07 share-contains 'GOCLOCK.ALARM' 'gocal2 2 '
vgate_assert 07 share-contains 'GOCLOCK.ALARM' ' 0645 d+'
vgate_assert 07 share-contains 'GOCLOCK.ALARM' ' 1920 o+'
# One key armed the 1-minute preset and it fired its marker, exactly once.
vgate_assert 07 serial-contains 'goclock: tab timer'
vgate_assert 07 serial-contains 'goclock: timer armed 60'
vgate_assert 07 serial-exact 'goclock: fired timer' 1
# The snapshot chord captured the session with the blob aboard.
vgate_assert 07 serial-contains 'gotabwm: state ask id='
vgate_assert 07 serial-contains 'gotabwm: state save id='
vgate_assert 07 serial-contains 'gotabwm: snapshot saved '
vgate_assert 07 serial-contains 'rx-goclock-v2-armed'
vgate_assert 07 serial-absent 'goclock: alarm refused'
vgate_assert 07 serial-absent 'goclock: alarm full'
vgate_assert 07 serial-absent 'goclock: deadline full'
vgate_assert 07 serial-absent 'goclock: timer refused'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'exited status=139'

# Byte-level on the share, same idiom as run 04: exactly one SESSION.TABS
# app_state blob IS the two-row gocal2 line — the daily row flags 'd+',
# the once row 'o+'.
vgate_assert 07 python <<'PY'
import os, re, sys
b = open(os.path.join(os.environ["VG_SHARE"], "SESSION.TABS"), "rb").read()
if b[0] != 2 or b[2] < 1:
    sys.exit("SESSION.TABS header ver=%d count=%d" % (b[0], b[2]))
off = 6 + 69 * b[2]
if len(b) < off + 6 + 8:
    sys.exit("SESSION.TABS too short for a state trailer: %d" % len(b))
if b[off:off+2] != b"AS" or b[off+2] != 1 or b[off+3] < 1:
    sys.exit("app_state header %r" % b[off:off+6])
asc = b[off+3]
pos = off + 6 + 8 * asc
hits = []
for i in range(asc):
    ent = b[off+6+8*i:off+14+8*i]
    ln = int.from_bytes(ent[4:8], "little")
    blob = b[pos:pos+ln]
    pos += ln
    if re.fullmatch(rb"gocal2 2 [0-9]+ 0645 d\+ [0-9]+ 1920 o\+", blob):
        hits.append((ent[0], ent[1], blob))
if len(hits) != 1 or hits[0][1] != 1:
    sys.exit("want exactly one appver=1 two-row gocal2 blob, found %r" % hits)
print("SESSION.TABS app_state: idx=%d appver=%d blob=%r" % hits[0])
PY

# --- run 08 (M152b): restore boot — both rows armed, the daily re-armed ---
# A fresh boot's session load mode=restore re-execs GOCLOCK; restore_state
# hands the gocal2 blob back (the share file agrees — file wins on a tie)
# and each row re-arms under its index id: `alarm restored HH:MM daily`
# for the repeater, `alarm restored HH:MM once` for the one-shot. No
# timer comes back — a countdown is a deadline, not a record. Tail
# cleanup leaves the share empty of clock state for the next iteration.
vgate_file script-08.txt <<'EOF'
echo rx-goclock-08-boot
EOF

vgate_file script3-08.txt <<'EOF'
vf rm SESSION.TABS
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
vf rm GOCLOCK.ALARM
echo rx-goclock-v2-restored
EOF

vgate_run 08 -- \
    --screen '$RUN_DIR/screen-08' \
    --via-virtio \
    --script '$RUN_DIR/script-08.txt' \
    --script3 '$RUN_DIR/script3-08.txt' \
    --script3-after 'goclock: alarm restored 19:20' \
    --script-expect 'rx-goclock-v2-restored' --timeout 300

vgate_assert 08 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 08 serial-contains 'gotabwm: mode live'
vgate_assert 08 serial-contains 'gotabwm: session load n='
vgate_assert 08 serial-contains ' mode=restore'
vgate_assert 08 serial-contains 'gotabwm: session reexec n='
vgate_assert 08 serial-contains 'gotabwm: session exec GOCLOCK.ELF'
vgate_assert 08 serial-contains 'goclock: declare accepted'
# The stored blob came back through restore_state...
vgate_assert 08 serial-contains 'goclock: state restored'
# ...and both rows re-armed: the daily one armed to ring again tomorrow.
vgate_assert 08 serial-contains 'goclock: alarm restored 06:45 daily'
vgate_assert 08 serial-contains 'goclock: alarm restored 19:20 once'
vgate_assert 08 serial-contains 'rx-goclock-v2-restored'
vgate_assert 08 serial-absent 'goclock: state refused'
vgate_assert 08 serial-absent 'goclock: alarm file bad'
vgate_assert 08 serial-absent 'goclock: deadline full'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-absent 'exited status=139'

# --- run 09 (#2940): the enforce leg — the clock's writes land under --------
# mode=enforce, not only under the audit default. A run-scoped share
# (`--cvc-file`, the go-agentd posture-leg pattern: a later --cvc-file in a
# run's own flags overrides the armed share for that boot only) carries a
# GRANTS.TXT of `#v1 mode=enforce` and NO user rows, so the compiled base
# rows decide — under #2939's table GOCLOCK.ELF's row carries `file`, so the
# arm's crash-safe /host/GOCLOCK.ALARM write and the save_ask's staged
# /host/APPSTATE.<win> write both land. A row that still lacked `file`
# would fail BY NAME — `refused:file_denied name=GOCLOCK.ELF word=file`
# plus the app's own `goclock: alarm save failed rc=` — never quietly; the
# asserts pin that refusal's absence AND the audit receipt's absence (the
# enforce posture), while the python hook proves the share's GRANTS.TXT
# really carried mode=enforce.
#
# The seat execs from the monitor on a wm=none copy (no autostart) so a
# prior iteration's SESSION.TABS cannot pre-restore a second clock before
# the leading `vf rm`s; the boot script cleans the share first, which is
# what makes the leg vgate_repeat-safe.

vgate_setup_python <<'PY'
# Declared LAST of this spec's setup hooks so the copy sees the armed
# share's final state, then layers the enforce posture on top.
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
enf = os.path.join(os.environ["RUN_DIR"], "enf-share")
if os.path.exists(enf):
    shutil.rmtree(enf)
shutil.copytree(share, enf)
open(os.path.join(enf, "GRANTS.TXT"), "w").write("#v1 mode=enforce\n")
open(os.path.join(enf, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
print("enf-share: %d files, GRANTS.TXT mode=enforce, wm=none"
      % len(os.listdir(enf)))
PY

vgate_file script-09.txt <<'EOF'
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
vf rm NOTIFY.HIST
vf rm GOCLOCK.ALARM
wm
exec GOTABWM.ELF
EOF

vgate_file script2-09.txt <<'EOF'
exec GOCLOCK.ELF
EOF

vgate_file script3-09.txt <<'EOF'
echo rx-goclock-enf
EOF

vgate_run 09 -- \
    --screen '$RUN_DIR/screen-09' \
    --via-virtio \
    --cvc-file '$RUN_DIR/enf-share' \
    --script '$RUN_DIR/script-09.txt' \
    --script2 '$RUN_DIR/script2-09.txt' \
    --script2-after 'gotabwm: mode live' \
    --input-chords 'right,right,right,2,3,5,9,return,ctrl-shift-s' \
    --input-chords-after 'goclock: painted epoch=' \
    --script3 '$RUN_DIR/script3-09.txt' \
    --script3-after 'gotabwm: snapshot saved ' \
    --script-expect 'rx-goclock-enf' --timeout 300

vgate_assert 09 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 09 serial-contains 'gotabwm: mode live'
vgate_assert 09 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 09 serial-contains 'goclock: declare accepted'
vgate_assert 09 serial-contains 'goclock: tab alarm'
vgate_assert 09 serial-contains 'goclock: alarm armed 23:59 daily'
# The arm's durable write landed: under enforce a missing `file` word
# would refuse it BY NAME, so `alarm saved` can only print because the
# row carried file and the write went through.
vgate_assert 09 serial-contains 'goclock: alarm saved'
# The unsolicited save_state push: the app staged /host/APPSTATE.<win>
# itself (same `file` word, same receipt surface).
vgate_assert 09 serial-contains 'goclock: state posted'
# The snapshot chord's exchange, seat side: ask -> the app's staged
# blob -> stored -> bundle.
vgate_assert 09 serial-contains 'gotabwm: state ask id='
vgate_assert 09 serial-contains 'gotabwm: state save id='
vgate_assert 09 serial-contains 'gotabwm: snapshot saved '
vgate_assert 09 serial-contains 'rx-goclock-enf'
# The enforce legs' named failures, absent by name — a write refused
# under enforce names its binary and its word, never silently.
vgate_assert 09 serial-absent 'refused:file_denied name=GOCLOCK.ELF'
vgate_assert 09 serial-absent 'refused:file_denied name=GOTABWM.ELF'
vgate_assert 09 serial-absent 'refused:'
# Posture: nothing audit-receipted — audit only receipts denied calls,
# so this line also proves the boot really ran under enforce's shape.
vgate_assert 09 serial-absent 'verdict=audit:'
vgate_assert 09 serial-absent 'goclock: alarm save failed'
vgate_assert 09 serial-absent 'goclock: deadline full'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 serial-absent 'exited status=139'

# The share evidence (this run's share is enf-share, not the armed one —
# share-* asserts read the armed share, so the check is python): the
# GRANTS.TXT the boot read really was `#v1 mode=enforce` with no user
# rows, GOCLOCK.ALARM carries the armed row, and SESSION.TABS's AS
# trailer carries the app's blob — proof the APPSTATE.<win> staging
# write happened (the envelope's bytes ride no other channel).
vgate_assert 09 python <<'PY'
import os, re, sys
sh = os.path.join(os.environ["RUN_DIR"], "enf-share")
g = open(os.path.join(sh, "GRANTS.TXT")).read()
if g != "#v1 mode=enforce\n":
    sys.exit("enforce share GRANTS.TXT is %r — not the bare enforce header"
             % g)
b = open(os.path.join(sh, "GOCLOCK.ALARM"), "rb").read()
if not re.fullmatch(rb"gocal2 1 [0-9]+ 2359 d\+\n?", b):
    sys.exit("GOCLOCK.ALARM = %r, want one armed gocal2 row" % b)
t = open(os.path.join(sh, "SESSION.TABS"), "rb").read()
if t[0] != 2 or t[2] < 1:
    sys.exit("SESSION.TABS header ver=%d count=%d" % (t[0], t[2]))
off = 6 + 69 * t[2]
if len(t) < off + 6 + 8 or t[off:off+2] != b"AS" or t[off+2] != 1 or t[off+3] < 1:
    sys.exit("no app_state trailer: %r" % t[off:off+6])
asc = t[off+3]
pos = off + 6 + 8 * asc
hits = []
for i in range(asc):
    ent = t[off+6+8*i:off+14+8*i]
    ln = int.from_bytes(ent[4:8], "little")
    blob = t[pos:pos+ln]
    pos += ln
    if re.fullmatch(rb"gocal2 1 [0-9]+ 2359 d\+", blob):
        hits.append((ent[0], ent[1], blob))
if len(hits) != 1 or hits[0][1] != 1:
    sys.exit("want exactly one appver=1 gocal2 blob under enforce, found %r"
             % hits)
if not os.path.getsize(os.path.join(sh, "SNAPSHOT.BUNDLE")):
    sys.exit("SNAPSHOT.BUNDLE missing or empty")
print("enforce leg: GRANTS.TXT mode=enforce, GOCLOCK.ALARM row landed, "
      "SESSION.TABS blob %r, bundle present" % hits[0][2])
PY

# --- run 10 (M178c #3146): the named-zone row — World row + seat face -------
# A run-scoped share (`--cvc-file`, the run-09 pattern) carries SETTINGS.TXT
# with `timezone=Europe/Berlin`, so the seat reads the row at boot — before
# its first chromeTick — and GOCLOCK's own settings.Load picks it up at
# exec. Two independent witnesses make the leg: the serial zone markers
# (`goclock: zones local=Europe/Berlin`, `goclock: zone 0 Europe/Berlin`)
# plus row 0's pixels glyph-decoded against python's zoneinfo at the
# painted epoch (the run-01 probe, scoped to the named row — its string is
# 33-34 chars: `YYYY-MM-DD HH:MM:SS CEST UTC+02:00`), and the seat clock's
# `gotabwm: clock HH:MM:SS` checked against the Berlin faces the host's own
# epoch window allows. The check is DST-boundary correct by construction —
# it computes the rule's answer, it does not pin CEST.
vgate_setup_python <<'PY'
# Declared LAST of this spec's setup hooks so the copy sees the armed
# share's final state, then layers the named-zone row on top. The boot
# epoch is sampled here too — the seat clock check needs the same host
# window the go-sh legs use.
import os, shutil, time
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
tz = os.path.join(os.environ["RUN_DIR"], "tz-share")
if os.path.exists(tz):
    shutil.rmtree(tz)
shutil.copytree(share, tz)
open(os.path.join(tz, "SETTINGS.TXT"), "w").write(
    "#v2\ntimezone=Europe/Berlin\n")
for stale in ("SESSION.TABS", "GOCLOCK.ALARM"):
    p = os.path.join(tz, stale)
    if os.path.exists(p):
        os.remove(p)
with open(os.path.join(os.environ["RUN_DIR"], "host-epoch-start.txt"), "w") as fh:
    fh.write(repr(time.time()))
print("tz-share: %d files, timezone=Europe/Berlin" % len(os.listdir(tz)))
PY

vgate_file script-10.txt <<'EOF'
vf rm SESSION.TABS
echo rx-goclock-10-boot
EOF

vgate_file script2-10.txt <<'EOF'
exec GOCLOCK.ELF
EOF

vgate_file script3-10.txt <<'EOF'
vf rm SESSION.TABS
echo rx-goclock-tz-ok
EOF

vgate_run 10 -- \
    --screen '$RUN_DIR/screen-10' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-10' \
    --cvc-file '$RUN_DIR/tz-share' \
    --script '$RUN_DIR/script-10.txt' \
    --script2 '$RUN_DIR/script2-10.txt' \
    --script2-after 'gotabwm: mode live' \
    --script3 '$RUN_DIR/script3-10.txt' \
    --script3-after 'goclock: painted epoch=' \
    --script3-delay 10 \
    --snapshot-after 'goclock: painted epoch=' \
    --snapshot-after 'rx-goclock-tz-ok' \
    --script-expect 'rx-goclock-tz-ok' --timeout 300

vgate_assert 10 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 10 serial-contains 'gotabwm: mode live'
vgate_assert 10 serial-contains 'gotabwm: clock-source kernel'
vgate_assert 10 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 10 serial-contains 'goclock: declare accepted'
vgate_assert 10 serial-contains 'goclock: zones local=Europe/Berlin n=13'
vgate_assert 10 serial-contains 'goclock: zone 0 Europe/Berlin'
vgate_assert 10 serial-contains 'goclock: painted epoch='
vgate_assert 10 serial-contains 'rx-goclock-tz-ok'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 serial-absent 'exited status=139'

# The seat clock's local face: the one-shot `gotabwm: clock HH:MM:SS` marker
# is the kernel epoch under the row. The host computes every Berlin face
# the epoch window could show (the marker prints seconds after boot; the
# window brackets boot with the go-sh legs' 60 s slack) and requires the
# marker to be one of them — a face that read UTC would be two hours off.
vgate_assert 10 python <<'PY'
import datetime, glob, os, re, sys, time, zoneinfo
rd = os.environ["RUN_DIR"]
ser_hits = sorted(glob.glob(os.path.join(rd, "vm-serial-10*.log")),
                  key=os.path.getmtime)
if not ser_hits:
    sys.exit("no serial log for run 10")
ser = open(ser_hits[-1], errors="replace").read()
mc = re.search(r"(?m)^gotabwm: clock (\d\d:\d\d:\d\d)$", ser)
if not mc:
    sys.exit("no 'gotabwm: clock' marker in serial")
face = mc.group(1)
with open(os.path.join(rd, "host-epoch-start.txt")) as fh:
    host_start = float(fh.read())
host_end = time.time()
zi = zoneinfo.ZoneInfo("Europe/Berlin")
faces = set()
e = int(host_start) - 90
while e <= host_end + 90:
    loc = datetime.datetime.fromtimestamp(e, datetime.timezone.utc).astimezone(zi)
    faces.add(loc.strftime("%H:%M:%S"))
    e += 1
if face not in faces:
    sys.exit("seat clock face %s is not a Europe/Berlin face in the host "
             "window [%d, %d]" % (face, host_start, host_end))
print("seat clock %s is a Europe/Berlin face inside the host window" % face)
PY

# The named world row, as pixels: row 0 is the settings row — decode its
# glyph cells and require the exact clockfmt string python computes for
# the painted epoch (or a second either side of it, the run-01 lag window).
vgate_assert 10 snapshot 'snap-10-*.raw' <<'PY'
import datetime, os, re, sys, time, glob as _glob, zoneinfo

W, H = 1280, 720
need = W * H * 4
snaps = sorted(_glob.glob(os.path.join(os.path.dirname(sys.argv[1]),
                                       "snap-%s-*.raw"
                                       % re.match(r"snap-(\w+)-\d+\.raw",
                                                  os.path.basename(sys.argv[1])).group(1))),
               key=os.path.getmtime)
frames = []
for p in snaps:
    raw = open(p, "rb").read()
    if len(raw) >= need:
        frames.append((os.path.basename(p), raw))
if not frames:
    sys.exit("no complete snapshot in %s" % snaps)

def px(raw, x, y):
    off = (y * W + x) * 4
    b, g, r = raw[off], raw[off + 1], raw[off + 2]
    return (r, g, b)

def lum(p):
    return p[0] * 0.30 + p[1] * 0.55 + p[2] * 0.15

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

tag = re.match(r"snap-(\w+)-\d+\.raw", os.path.basename(sys.argv[1]))
ser_hits = sorted(
    _glob.glob(os.path.join(os.path.dirname(sys.argv[1]),
                            "vm-serial-%s*.log" % tag.group(1))),
    key=os.path.getmtime)
if not ser_hits:
    sys.exit("no serial log for snap tag %s" % tag.group(1))
ser = open(ser_hits[-1], errors="replace").read()

mz = re.search(r"(?m)^goclock: zones local=(\S+) n=(\d+)$", ser)
if not mz:
    sys.exit("no 'goclock: zones' marker in serial")
local_label, nrows = mz.group(1), int(mz.group(2))
if local_label != "Europe/Berlin":
    sys.exit("local row is %r, want Europe/Berlin" % local_label)
z0 = re.search(r"(?m)^goclock: zone 0 (\S+)$", ser)
if not z0 or z0.group(1) != "Europe/Berlin":
    sys.exit("zone 0 marker = %r, want Europe/Berlin"
             % (z0.group(1) if z0 else None))

me = list(re.finditer(r"(?m)^goclock: painted epoch=(\d+)$", ser))
if not me:
    sys.exit("no painted-epoch markers in serial")
epoch = int(me[-1].group(1))

zi = zoneinfo.ZoneInfo("Europe/Berlin")
def expected(e):
    loc = datetime.datetime.fromtimestamp(e, datetime.timezone.utc).astimezone(zi)
    off = int(loc.utcoffset().total_seconds())
    canon = "UTC" if off == 0 else "UTC%s%02d:%02d" % (
        "+" if off >= 0 else "-", abs(off) // 3600, abs(off) // 60 % 60)
    return "%s %s %s" % (loc.strftime("%Y-%m-%d %H:%M:%S"),
                         loc.tzname(), canon)

def decode_cell(raw, x0, y0):
    lums = [lum(px(raw, x0 + k % 8, y0 + k // 8)) for k in range(64)]
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

# Candidates: EVERY epoch the app painted, plus a second either way — the
# capture can lag the last marker by far more than run 01's 10 s window
# under vgate_repeat contention (observed 10-01: a 13 s-stale frame that
# was itself a correct face). The row must render one of the app's own
# painted epochs, which is the honest bound.
cand = sorted({e + d for e in (int(m.group(1)) for m in me)
               for d in (-1, 0, 1)})
matched, decoded, want = False, None, None
for name, raw in frames:
    for e in cand:
        w = expected(e)
        text = "".join(decode_cell(raw, 18 + j * 8, 61)
                       for j in range(len(w)))
        if text == w:
            matched, decoded, want = True, text, w
if not matched:
    decoded = "".join(decode_cell(frames[-1][1], 18 + j * 8, 61)
                      for j in range(34))
    sys.exit("row 0 is not a Europe/Berlin face across %d captures "
             "(epoch %d; decoded %r, want e.g. %r)"
             % (len(frames), epoch, decoded, expected(epoch)))
print("world row 0 = %r (epoch ~%d, %s)" % (want or decoded, epoch, "matched"))
PY
