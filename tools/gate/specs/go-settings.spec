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
# Tab strip {8,8,544,20}: four 136px cells — Services centre local
# (212,18) -> screen (260,66). `shadow` (an on|off toggle) is display row
# 4 on a fresh share: row local y 122..140 — the press lands on the row
# BODY local (200,131) -> screen (248,179), the new M122e gesture (not
# the toggle plate, which rowControlClick already owned).
# Each press is a d+u PAIR (the run-04 lesson: one 'c' message can land
# inside a single slow pointer tick and collapse to no edge).
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --pointer-virtio '248,179,d;248,179,u;260,66,d;260,66,u' \
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
