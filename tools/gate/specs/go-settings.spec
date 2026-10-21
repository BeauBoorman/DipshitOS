# go-settings.spec -- M122e (issue #2574): the clickable GOSET leg — a
# --pointer-virtio press toggles a settings row, a press on a tab header
# opens that pane, Esc backs out to Settings before quitting, and the
# toggled row persists into the share's SETTINGS.TXT.
#
# No seat is staged on purpose: under gotabwm the seat's content forward
# (wmctl cmd 15) reaches the kernel's LOCAL path only — terminal selection
# and mouse reports — and a hosted app's window never sees MOUSE_* (the
# pointer_tick early-return under wm_owns_input). The shim's own
# pointer_tick hit-tests and pushes window-local MOUSE_DOWN/UP, the same
# path go-calc run 04 pins, so this leg can only exist in a shim boot.
# `goset: declare refused` is load-bearing evidence for it.
#
# HOST PREREQUISITE:
#   bash tools/go/build-goset.sh  ->  .build/go/GOSET.ELF

vgate_name go-settings "issue #2574 M122e: GOSET's click surface — toggle row, tab headers, Esc back-out — under the shim's own pointer delivery"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec GOSET.ELF
EOF

vgate_file script3.txt <<'EOF'
echo rx-goset-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOSET.ELF")
if not os.path.exists(src):
    sys.exit("GOSET.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goset.sh")
shutil.copy(src, os.path.join(share, "GOSET.ELF"))
print("staged GOSET.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOSET.ELF")))
PY

# The window opens at (48,48) native 560x360 — local = screen - (48,48).
# Tab strip {8,8,544,20}: SIX ~90px cells since M165b's access tab —
# Services centre local (136,18) -> screen (184,66). `shadow` (an on|off
# toggle) is display row 4 on a fresh share: row local y 122..140 — the
# press lands on the row BODY local (200,131) -> screen (248,179), the
# new M122e gesture (not the toggle plate, which rowControlClick already
# owned).
# Each press is a d+u PAIR (the run-04 lesson: one 'c' message can land
# inside a single slow pointer tick and collapse to no edge).
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --pointer-virtio '248,179,d;248,179,u;184,66,d;184,66,u' \
    --pointer-virtio-after 'goset: ready ' \
    --input-chords 'escape,return,escape' \
    --input-chords-after 'goset: tab services' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'goset: close' \
    --script-expect 'rx-goset-ok' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
# Shim-mode proof: the seat never registered, so the kernel's own pointer
# path delivered every press — the only route MOUSE_DOWN reaches GOSET.
vgate_assert 01 serial-contains 'exec: loaded GOSET.ELF'
vgate_assert 01 serial-contains 'goset: declare refused'
vgate_assert 01 serial-contains 'goset: ready keys='
# The click legs: the toggle press set the row, the tab-header press
# opened Services, and the Esc pop landed back on Settings — the `goset:
# tab settings` line is the pop's only producer in this run (the pointer
# batch never clicks the Settings cell).
vgate_assert 01 serial-contains 'goset: set shadow=on'
vgate_assert 01 serial-contains 'goset: tab services'
vgate_assert 01 serial-contains 'goset: services n='
vgate_assert 01 serial-exact 'goset: tab settings' 1
vgate_assert 01 serial-contains 'goset: saved keys='
vgate_assert 01 serial-contains 'goset: close'
vgate_assert 01 serial-contains 'goset OK'
# The toggled value persisted: the share's SETTINGS.TXT carries shadow=on.
vgate_assert 01 share-contains 'SETTINGS.TXT' 'shadow=on'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
vgate_assert 01 serial-contains 'rx-goset-ok'

# The chain as an ordering pin: set (the toggle click) -> tab services
# (the header click) -> tab settings (Esc's pop) -> saved (Enter) ->
# close (Esc's quit) — each marker can appear without the others, so the
# order is the evidence.
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def at(pat, what):
    m = re.search(pat, ser)
    if not m:
        sys.exit("no %s in the serial log" % what)
    return m

setm = at(r"goset: set shadow=on", "the toggle click's set")
svc = at(r"goset: tab services", "the tab-header click")
back = at(r"goset: tab settings", "Esc's pop to Settings")
saved = at(r"goset: saved keys=", "Enter's save")
close = at(r"goset: close", "Esc's quit")

if not (setm.start() < svc.start() < back.start() < saved.start() < close.start()):
    sys.exit("click chain out of order: set=%d tab=%d back=%d saved=%d close=%d"
             % (setm.start(), svc.start(), back.start(), saved.start(), close.start()))
print("click chain ordered: set < tab services < tab settings < saved < close")
PY

# --- run 02 (M165b / #2983): the a11y leg under the Go seat -----------------
# The seat CANNOT be staged under its real name: this spec's other run is a
# shim boot whose asserts hinge on `goset: declare refused`, and a share
# carrying GOTABWM.ELF autostarts the seat at boot. It is staged as
# GOTABWM.STAGE and renamed in-run (`vf mv`) — the file is literally
# GOTABWM.ELF again by the time `exec` loads it, so grants and markers are
# the autostart path's own. GOSET then opens under it, the typed `access`
# line opens the sixth tab, and two typed key=value lines set + save
# a11y.contrast=high and a11y.reduce_motion=on through the panel's
# crash-safe publish. GOCALC — an ApplySettings caller — then opens and a
# kind-4 scanout snap reads its window's background pixel as the
# high-contrast Bg token; GOCLOCK's armed 3-second timer produces the
# toast that prints `gotabwm: notify fade=off`.
#
# The file — not a bus subscription — is the reduce-motion channel: the
# seat re-reads a11y.reduce_motion per queued toast, so a GOSET save from
# seconds ago applies to the very next one (see notify.go's
# refreshReduceMotion).
#
# Stage order is load-bearing: GOSET alone at first (it must hold focus
# for the typed lines), then CALC + CLOCK together after the first save —
# CALC's exec is what the snapshot's win-rect correlation anchors on.
#
# HOST PREREQUISITE (fails honestly when missing):
#   bash tools/go/build-gotabwm.sh  -> .build/go/GOTABWM.ELF
#   bash tools/go/build-gosh.sh     -> .build/go/GOSH.ELF (first-boot workspace)
#   bash tools/go/build-goset.sh    -> .build/go/GOSET.ELF
#   bash tools/go/build-gocalc.sh   -> .build/go/GOCALC.ELF
#   bash tools/go/build-goclock.sh  -> .build/go/GOCLOCK.ELF

vgate_file script-02.txt <<'EOF'
vf mv GOTABWM.STAGE GOTABWM.ELF
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
exec GOSET.ELF
EOF

vgate_file script3-02.txt <<'EOF'
exec GOCALC.ELF
exec GOCLOCK.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for name, how in (("GOSH", "build-gosh.sh"), ("GOSET", "build-goset.sh"),
                  ("GOCALC", "build-gocalc.sh"), ("GOCLOCK", "build-goclock.sh")):
    src = os.path.join(".build", "go", name + ".ELF")
    if not os.path.exists(src):
        sys.exit(name + ".ELF missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name + ".ELF"))
    print("staged %s.ELF into share (%d bytes)" %
          (name, os.path.getsize(os.path.join(share, name + ".ELF"))))
# The seat travels under a name the boot autostart cannot see (see the
# run-02 header: the shim run needs it absent).
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.STAGE"))
print("staged GOTABWM.ELF as GOTABWM.STAGE (%d bytes)" % os.path.getsize(src))
PY

# The input-string is three typed lines: `access` opens the tab (the
# `goset: tab access` marker is its only producer), then each key=value
# line is apply+save on Enter — two `goset: set`/`goset: saved` pairs.
# script3 waits on the SECOND save (keys=15: the fresh share's 13 + both
# a11y rows) — firing on the first `saved` would exec the apps while the
# third line was still typing, and a declare's focus steal would feed the
# tail of it to the calculator (observed 2026-10-21: reduce_motion lost,
# no fade=off marker, the run timed out on its own expect). Chords arm
# GOCLOCK's 3-second custom timer on
# the Timer tab ('e' opens the seconds entry; a bare '3' would arm the
# 3-minute preset) — the go-clock run-02 idiom — and the snapshot trigger
# is `timer armed 3`: CALC's window is composited by then and the toast
# has not yet fired, so the probe reads a clean desktop.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-02' \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: mode live' \
    --input-string $'access\na11y.contrast=high\na11y.reduce_motion=on\n' \
    --input-string-after 'goset: ready ' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'goset: saved keys=15' \
    --input-chords 'right,right,e,3,return' \
    --input-chords-after 'goclock: painted epoch=' \
    --snapshot-after 'goclock: timer armed 3' \
    --script-expect 'gotabwm: notify fade=off' --timeout 300

# The seat was absent at boot (shim note), then the staged rename+exec
# seated it — `mode live` is the seat's own settled marker.
vgate_assert 02 serial-contains 'GOTABWM.ELF not on the share (shim compositing)'
vgate_assert 02 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 02 serial-contains 'gotabwm: mode live'
vgate_assert 02 serial-contains 'exec: loaded GOSET.ELF'
# Under the seat the declare is accepted — the typed lines land in a
# hosted window, not a shim orphan.
vgate_assert 02 serial-contains 'goset: declare accepted'
vgate_assert 02 serial-contains 'goset: ready keys='
# The access tab opened, and both rows were set through it.
vgate_assert 02 serial-contains 'goset: tab access'
vgate_assert 02 serial-contains 'goset: set a11y.contrast=high'
vgate_assert 02 serial-contains 'goset: set a11y.reduce_motion=on'
vgate_assert 02 serial-contains 'goset: saved keys='
# Both rows persisted on the share.
vgate_assert 02 share-contains 'SETTINGS.TXT' 'a11y.contrast=high'
vgate_assert 02 share-contains 'SETTINGS.TXT' 'a11y.reduce_motion=on'
# CALC opened as a hosted window and presented.
vgate_assert 02 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 02 serial-contains 'gocalc: declare accepted'
vgate_assert 02 serial-contains 'gocalc: present'
# The toast chain: armed, fired, queued — with the ramp switched off.
vgate_assert 02 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 02 serial-contains 'goclock: timer armed 3'
vgate_assert 02 serial-contains 'gotabwm: notify id='
vgate_assert 02 serial-contains 'gotabwm: notify fade=off'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# The seat's workspace window — the surface hosted apps are composited
# into — is the one win rect the seat reports (1024,528,256,192; observed
# on both the go-wm-default single-app boot and this run). Its interior
# must read the DarkHC Bg token (0x000000), never the plain Dark one
# (0x182026) — ApplySettings took the a11y.contrast=high row GOSET saved.
vgate_assert 02 snapshot 'snap-02-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %d (%dx%d BGRX)"
             % (len(raw), W * H * 4, W, H))

def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])  # BGRX -> (r, g, b)

HC_BG   = (0x00, 0x00, 0x00)  # theme.DarkHC.Bg
DARK_BG = (0x18, 0x20, 0x26)  # theme.Dark.Bg — the unthemed answer

x, y, w, h = 1024, 528, 256, 192  # gotabwm's workspace win rect
samples = [px(x + int(w * fx / 10), y + int(h * fy / 10))
           for fx in range(1, 10) for fy in range(1, 10)]
hc = sum(1 for c in samples if c == HC_BG)
dark = sum(1 for c in samples if c == DARK_BG)
if hc * 2 < len(samples):
    sys.exit("workspace window: only %d/81 px are the high-contrast Bg — "
             "ApplySettings did not take a11y.contrast=high" % hc)
if dark > 2:
    sys.exit("workspace window: %d px are the plain Dark Bg — the "
             "high-contrast variant did not apply" % dark)
print("hosted workspace (%dx%d@%d,%d): %d/81 px high-contrast Bg, %d plain-Dark strays"
      % (w, h, x, y, hc, dark))
PY
