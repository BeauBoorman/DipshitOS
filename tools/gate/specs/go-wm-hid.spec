# go-wm-hid.spec -- M63a–e (issues #1419–#1423) class-B gate: GOTABWM HID
# capstone, plus M69c/c2 (#1530/#1535): token serial/pixel probe and the
# Ctrl+Space launcher from an honest APPS.TXT.
#
# Seed wm=none, exec GOTABWM.ELF (explicit seat, not the boot-default path).
# SPIKE + --via-virtio. Pairing is GOEDIT+GOTERM (#1405) on runs 01/02.
#
# Run 01: last declare is GOTERM (right cell, focused). After `rail n=2`,
# click `(320,10)` so TASKBAR focuses GOEDIT. `--input-string 'XYZ'` waits
# on `gotabwm: rail-click id=` (not early `goedit: present`). Chords after
# `goedit: dirty` still belong to the seat.
#
# Run 02: same pairing. `--pointer-virtio '320,10,d;960,10,u'` after
# `rail n=2` (press unfocused cell, release over the other → Reorder).
# Pin/Alt+Tab stay on run 01; this boot is the HID drag leg. go-wm-tabs
# `reorder 0->1` is M62d choreography, not this path.
#
# Run 03: seat only (no GOEDIT/GOTERM — three Go runtimes is the #1449 wall).
# `dui focus 0` after `gotabwm: win focus` supplies the M57b blur (same
# handshake as go-wm-seat). After `gotabwm: present`, Ctrl+Space opens the
# APPS.TXT launcher, type `calc` + Enter execs GOCALC.ELF as a hosted tab.
# Tokens marker pins the dark table (same shape as sysmon: tokens). A GPU
# pixel of compose-N is not what --cvc-snap returns on this seat-only boot
# (observed: 0x101418 boot fill / terminal bg). live-tokens owns window
# pixels. The catalog must not offer NOTEPAD.ELF / CALC.BIN.
#
# M71f (#1565): the same catalogue assert now covers the settings panel --
# GOSET.ELF must be offered and the retired SETTINGS.BIN must not, so the
# deletion cannot be quietly undone by an APPS.TXT row.
#
# M71g (#1566): and the process monitor -- GOTOP.ELF must be offered while
# TOP.BIN and SYSMON.BIN must not, so the same deletion of the two Zig
# programs cannot be silently undone by a manifest row either.
#
# M71h (#1567): and the image viewer -- GOVIEW.ELF must be offered while
# VIEW.BIN must not, for the same reason.
#
# Runs 04/05 (M71d / #1563, M48 BT1): seat-only. One client (GOCALC.ELF via
# script2), whose single-tab path auto-closes it after hostTicks, recording the
# bin in the reopen LIFO. Run 04's chord fires on that close marker
# (ctrl-shift-t reopens the closed bin); run 05's chord fires on the client's
# tab-open marker (ctrl-shift-d duplicates the focused tab). The two chords are
# proven in SEPARATE boots on purpose: the cv-input chord transport paces at a
# fixed 0.25 s/stroke and IGNORES --input-chords-delay (VMRunner main.swift,
# DELIVERY TRANSPORT), so in one batch the duplicate chord always lands before
# the re-exec'd clone has declared and DuplicateFocused() honest-no-ops --
# measured 2026-09-24 (and identically at baseline 8bcda39): `reopen` prints,
# `duplicate` does not. Seat-only because three Go runtimes is the #1449 wall.
# Run 02's M62e SESSION.TABS is cleared before this boot: a restore sets
# stripDone and skips the auto-close.
#
# Run 07 (M79f / #1717): four Go runtimes (seat + GOEDIT + GOTERM + GOCALC)
# at GOMAXPROCS=1 — that fit the M65 max_tasks=16 budget (64 after M129b).
# Once the rail
# reaches n=3, one chord batch proves Ctrl+Tab wrapping from the focused third
# cell to cell 1, then Ctrl+2 focusing cell 2. Both chords intentionally emit
# the established alt-tab marker chain because they share the same focus path.
#
# Run 08 (M82c / #1770): the global shortcuts registry. The monitor seeds
# GOTABWM.CHORDCONFLICT, so the seat's prologue feeds the checker the
# deliberately conflicting fixture (FIXTURE.ELF claiming the seat's palette
# chord — pin's home before M121a) and prints the full named
# refusal, then the whole table (one `gotabwm: chord` line per row) and the
# summary. The seat carries on with the UNTOUCHED shipped table: the
# fixture is a refusal exercise, not a reconfiguration. GOSET then opens
# its shortcuts view with the panel's own registered chord (ctrl+shift+h,
# a GOSET.ELF app row — re-bound from ctrl+shift+s when M81g #1767 landed
# the seat's snapshot arm on that chord first) — the registry is visible
# to a user, not just asserted. Two Go runtimes is inside the #1449 wall.
#
# Run 09/10 (M83d2 / #1786, M83e / #1778): the persisted DE layout. Run 10 is
# the dead keys: GOEDIT stages an accent, shows it, and resolves it to a
# composed letter or to literals, never dropping a key. Same two-runtime
# boot as run 09.
#
# Run 16 (M121b / #2565): run 07's three-client boot driving the tab chords —
# ctrl+shift+pageup/pagedown move the focused cell, ctrl+shift+n pins it to
# the front, ctrl+shift+w closes it. Reopen/duplicate keep runs 04/05.
#
# Run 21 (M191b / #3243): launcher verbs + filename hits — the filename
# hit as a second result kind, Tab arming the reveal verb, GOFILES
# opening the containing folder, and the M165f hand-off row as this
# face's answer to a content-intent query.
#
# Runs 17–19 (M121e / #2568): the undo chord on every surface it routes.
# One boot per surface — a focus switch cannot ride inside a chord batch:
# the seat's WM_KEY mirror lags the app's own KEY_DOWN delivery (measured
# 2026-10-19: ~90k serial lines on this boot shape), so a batch that
# alt-tabs and keeps typing lands its tail on the OLD focus. Run 17 is
# run 01's GOEDIT+GOTERM pair: XYZ into the editor, ctrl-z routes
# `undo id=` to the focused tab and the op ring reverts (`goedit: undo`),
# and the follow-up save writes the seed bytes exactly — the revert, not
# a repaint fib. Run 18 is run 04's single-tab boot: after the auto-close
# leaves an empty strip the same chord is the seat's own undo —
# `gotabwm: undo seat` pops the reopen LIFO. Run 19 hosts GOFILES alone on
# a one-file share: d,y trashes NOTE.TXT, and ctrl-z reaches the tty-bound
# tab as the 0x1a byte — the model's own restore path answers
# (`gofiles: restored`).

# Two equal-width cells on a 1280 rail: tab 0 [0,640)=(320,10), tab 1
# [640,1280)=(960,10). Zig's left-rail (158,70) is the wrong target.
# Pane rects include y=0. No client-area mouse. No edit/term rewrite.

# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-goedit.sh    ->  .build/go/GOEDIT.ELF
#   bash tools/go/build-goterm.sh    ->  .build/go/GOTERM.ELF
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#   bash tools/go/build-goset.sh     ->  .build/go/GOSET.ELF   (run 08)
#   bash tools/go/build-files.sh     ->  .build/go/GOFILES.ELF (runs 18-21)
#   bash tools/go/build-goclock.sh   ->  .build/go/GOCLOCK.ELF (run 22)
#
# exec-order: assert-proven -- each run ends on a script-only marker
# (`rx-gotabwm-hid-ok` / `rx-gotabwm-hid-drag-ok`), and every stage gate
# waits on guest output the program produces (`gotabwm: win focus`,
# `gotabwm: rail n=2`, `gotabwm: rail-click`, `goedit: dirty`,
# `wm: unregistered, shim resumed`).

vgate_name go-wm-hid "issues #1419–#1423 M63a-e + #1563 M71d + #1717 M79f: GOTABWM type-in, HID drag, BT1, ctrl-tab/ctrl-digit on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import runpy
runpy.run_path("tests/fixtures/desktop/m91/fresh.py")["stage"]({
    "GOTABWM": "build-gotabwm.sh", "GOEDIT": "build-goedit.sh",
    "GOTERM": "build-goterm.sh", "GOCALC": "build-gocalc.sh",
    "GOSET": "build-goset.sh", "GOSH": "build-gosh.sh",
})
PY

vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2.txt <<'EOF'
dui focus 0
echo m87-seat-flush-before
dui
# The rail orders cells by tab-open (declare) order and the clicks below
# hit cell 0, so GOEDIT must declare before GOTERM execs. `fg` after a
# backgrounded exec is the bounded-wait idiom (live-jobs.spec): it parks
# ~5 timer ticks while GOEDIT boots and declares, then reports the job
# still running — serializing the two execs without a sleep builtin.
exec GOEDIT.ELF &
fg
exec GOTERM.ELF
echo m87-seat-flush-after
dui
EOF

vgate_file script3.txt <<'EOF'
wm
dui
echo rx-gotabwm-hid-ok
EOF

vgate_file script3-drag.txt <<'EOF'
wm
dui
echo rx-gotabwm-hid-drag-ok
EOF

# M79a (#1704): the seat's bounded demo choreography (auto-close, the
# reorder/pin/split chain, the run budget) is DEMO mode, opted in by the
# PRESENCE of /host/GOTABWM.DEMO. This spec's runs drive it -- run 04's
# reopen chord fires ON the single-tab auto-close, run 05's duplicate chord on
# the tab-open marker -- so the trigger is seeded like any other share fixture;
# a daily session never stages it and gets the live seat (go-wm-seat run 05
# proves that path end to end).
vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
with open(os.path.join(share, "GOTABWM.DEMO"), "w") as f:
    f.write("demo\n")
print("seeded GOTABWM.DEMO (seat demo mode: bounded choreography)")
PY

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
print("staged GOTABWM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTABWM.ELF")))
src = os.path.join(".build", "go", "GOEDIT.ELF")
if not os.path.exists(src):
    sys.exit("GOEDIT.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goedit.sh")
shutil.copy(src, os.path.join(share, "GOEDIT.ELF"))
print("staged GOEDIT.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOEDIT.ELF")))
src = os.path.join(".build", "go", "GOTERM.ELF")
if not os.path.exists(src):
    sys.exit("GOTERM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goterm.sh")
shutil.copy(src, os.path.join(share, "GOTERM.ELF"))
print("staged GOTERM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTERM.ELF")))
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
# M82c (#1770): run 08 opens the shortcuts registry in the GO panel.
src = os.path.join(".build", "go", "GOSET.ELF")
if not os.path.exists(src):
    sys.exit("GOSET.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goset.sh")
shutil.copy(src, os.path.join(share, "GOSET.ELF"))
print("staged GOSET.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOSET.ELF")))
src = os.path.join(".build", "go", "GOSH.ELF")
if not os.path.exists(src):
    sys.exit("GOSH.ELF missing - build it first: bash tools/go/build-gosh.sh")
shutil.copy(src, os.path.join(share, "GOSH.ELF"))
# M190c (#3238): run 22's badge leg needs a toast poster — GOCLOCK's
# timer fires vi.Notify.
src = os.path.join(".build", "go", "GOCLOCK.ELF")
if not os.path.exists(src):
    sys.exit("GOCLOCK.ELF missing - build it first: bash tools/go/build-goclock.sh")
shutil.copy(src, os.path.join(share, "GOCLOCK.ELF"))
# M121e (#2568): run 17's GOFILES trash leg — one file so 'd' selects it.
src = os.path.join(".build", "go", "GOFILES.ELF")
if not os.path.exists(src):
    sys.exit("GOFILES.ELF missing - build it first: bash tools/go/build-files.sh")
shutil.copy(src, os.path.join(share, "GOFILES.ELF"))
fmu = os.path.join(share, "FMUNDO")
os.makedirs(fmu, exist_ok=True)
with open(os.path.join(fmu, "NOTE.TXT"), "w") as f:
    f.write("m121e trash-restore\n")
# M191b (#3243): run 21's filename hit — a one-file dir so the reveal
# verb's `GOFILES.ELF /host/LV` lands with VERB.TXT the selected row.
lv = os.path.join(share, "LV")
os.makedirs(lv, exist_ok=True)
with open(os.path.join(lv, "VERB.TXT"), "w") as f:
    f.write("m191b launcher verbs\n")
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
seed = os.path.join(ed, "SEED.TXT")
with open(seed, "wb") as f:
    f.write(b"seed-line\n")
print("seeded %s (%d bytes)" % (seed, os.path.getsize(seed)))
with open(os.path.join(ed, "M87.TXT"), "wb") as f:
    f.write(b"seed-line\n")
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("seeded SETTINGS.TXT (wm=none: shim-only boot, explicit seat opt-in)")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '320,10,c' \
    --pointer-virtio-after 'gotabwm: rail n=2' \
    --input-string 'XYZ' \
    --input-string-after 'gotabwm: rail-click id=' \
    --input-chords 'ctrl-s,ctrl-shift-n,alt-tab' \
    --input-chords-after 'goedit: dirty' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-ok' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 01 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: rail'
vgate_assert 01 serial-contains 'gotabwm: rail n=2'
vgate_assert 01 serial-contains 'gotabwm: ptr'
vgate_assert 01 serial-contains 'gotabwm: rail-click id='
vgate_assert 01 serial-contains 'goedit: present'
vgate_assert 01 serial-contains 'goterm: attached'
vgate_assert 01 serial-contains 'gotabwm: key'
vgate_assert 01 serial-contains 'goedit: dirty'
vgate_assert 01 serial-contains 'goedit: saved /host/EDIT/SEED.TXT n=13'
vgate_assert 01 serial-contains 'gotabwm: pin id='
vgate_assert 01 serial-contains 'gotabwm: alt-tab id='
vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-gotabwm-hid-ok'
vgate_assert 01 serial-absent 'goterm: line '
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
vgate_assert 01 python <<'PY'
import os, re

serial = open(os.environ["VG_SER"], errors="replace").read()
def kernel_presents(marker):
    match = re.search(
        re.escape(marker) + r".*?dui: windows=\d+ focused=\d+ presents=(\d+)",
        serial, re.S)
    if not match:
        raise SystemExit("missing seat-owned kernel-present checkpoint: " + marker)
    return int(match.group(1))

before = kernel_presents("m87-seat-flush-before")
after = kernel_presents("m87-seat-flush-after")
if before != after:
    raise SystemExit(f"kernel flushed over the owning seat: {before} -> {after}")
print(f"console/app-load batches preserve exclusive seat presentation: kernel presents={after}")
PY
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
order_re = re.compile(
    r"^gotabwm: order ids=(\d+),(\d+) pin=(\d),(\d) focus=(\d+)$")
rail2_re = re.compile(r"^gotabwm: rail n=2 focus=(\d+)$")
click_re = re.compile(r"^gotabwm: rail-click id=(\d+)$")
edit_re = re.compile(r"^goedit: open id=(\d+)$")
term_re = re.compile(r"^goterm: open id=(\d+)$")

def first_after(prefix):
    for i, line in enumerate(ser):
        if line.startswith(prefix):
            return i
    sys.exit("missing %s" % prefix)

def first_match(rx):
    for i, line in enumerate(ser):
        m = rx.match(line)
        if m:
            return i, m
    sys.exit("missing /%s/" % rx.pattern)

def first_order_after(start):
    for line in ser[start + 1:]:
        m = order_re.match(line)
        if m:
            return m
    sys.exit("no order line after index %d" % start)

edit_i, edit_m = first_match(edit_re)
term_i, term_m = first_match(term_re)
rail_i, rail_m = first_match(rail2_re)
click_i, click_m = first_match(click_re)
if click_i <= rail_i:
    sys.exit("rail-click must follow rail n=2 (rail@%d click@%d)" % (
        rail_i, click_i))
click_id = click_m.group(1)
edit_id = edit_m.group(1)
term_id = term_m.group(1)
if click_id != edit_id:
    sys.exit("rail-click id=%s is not GOEDIT id=%s (GOTERM id=%s)" % (
        click_id, edit_id, term_id))
if click_id == term_id:
    sys.exit("rail-click focused GOTERM id=%s" % term_id)
if click_id == rail_m.group(1):
    sys.exit("rail-click did not move focus (still %s)" % click_id)

click_o = first_order_after(click_i)
if click_o.group(5) != click_id:
    sys.exit("order after rail-click focus=%s want %s: %s" % (
        click_o.group(5), click_id, click_o.group(0)))
if click_o.group(1) != click_id:
    sys.exit("clicked cell 0 but order left id=%s want %s: %s" % (
        click_o.group(1), click_id, click_o.group(0)))

dirty_i = first_after("goedit: dirty")
if dirty_i <= click_i:
    sys.exit("goedit: dirty must follow rail-click (click@%d dirty@%d)" % (
        click_i, dirty_i))
saved_i = first_after("goedit: saved /host/EDIT/SEED.TXT n=13")
if saved_i <= dirty_i:
    sys.exit("goedit: saved must follow dirty (dirty@%d saved@%d)" % (
        dirty_i, saved_i))

pin_i = first_after("gotabwm: pin id=")
alt_i = first_after("gotabwm: alt-tab id=")
if pin_i <= saved_i:
    sys.exit("pin must follow GOEDIT save (saved@%d pin@%d)" % (saved_i, pin_i))
if alt_i <= pin_i:
    sys.exit("alt-tab marker must follow pin (pin@%d alt-tab@%d)" % (pin_i, alt_i))

pin_o = first_order_after(pin_i)
alt_o = first_order_after(alt_i)
if pin_o.group(3) != "1" and pin_o.group(4) != "1":
    sys.exit("pin chord left no pin bit: %s" % pin_o.group(0))
if alt_o.group(5) == pin_o.group(5):
    sys.exit("alt-tab did not change focus (still %s): pin=%s alt=%s" % (
        pin_o.group(5), pin_o.group(0), alt_o.group(0)))
if "1" not in (alt_o.group(3), alt_o.group(4)):
    sys.exit("pin bit lost after alt-tab: %s" % alt_o.group(0))

share = os.environ["VG_SHARE"]
path = os.path.join(share, "EDIT", "SEED.TXT")
want = b"seed-line\nXYZ"
got = open(path, "rb").read()
if got != want:
    sys.exit("SAVED CONTENT MISMATCH: got %r want %r" % (got, want))
print("rail-click GOEDIT id=%s (was focus %s) dirty then saved %r then pin %s then focus %s -> %s" % (
    click_id, rail_m.group(1), got, pin_o.group(0), pin_o.group(5), alt_o.group(5)))
PY

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '320,10,d;960,10,u' \
    --pointer-virtio-after 'gotabwm: rail n=2' \
    --script3 '$RUN_DIR/script3-drag.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-drag-ok' --timeout 300

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 02 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 02 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'gotabwm: rail n=2'
vgate_assert 02 serial-contains 'gotabwm: ptr'
vgate_assert 02 serial-contains 'gotabwm: rail-click id='
vgate_assert 02 serial-contains 'gotabwm: reorder 0->1'
vgate_assert 02 serial-contains 'gotabwm: close'
vgate_assert 02 serial-contains 'gotabwm OK'
vgate_assert 02 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 02 serial-contains 'rx-gotabwm-hid-drag-ok'
vgate_assert 02 serial-absent 'goterm: line '
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
order_re = re.compile(
    r"^gotabwm: order ids=(\d+),(\d+) pin=(\d),(\d) focus=(\d+)$")
rail2_re = re.compile(r"^gotabwm: rail n=2 focus=(\d+)$")
click_re = re.compile(r"^gotabwm: rail-click id=(\d+)$")
reorder_re = re.compile(r"^gotabwm: reorder (\d+)->(\d+)$")

def first_match(rx):
    for i, line in enumerate(ser):
        m = rx.match(line)
        if m:
            return i, m
    sys.exit("missing /%s/" % rx.pattern)

def first_order_after(start):
    for line in ser[start + 1:]:
        m = order_re.match(line)
        if m:
            return m
    sys.exit("no order line after index %d" % start)

def first_match_after(rx, start):
    for i, line in enumerate(ser[start + 1:], start + 1):
        m = rx.match(line)
        if m:
            return i, m
    sys.exit("missing /%s/ after index %d" % (rx.pattern, start))

rail_i, rail_m = first_match(rail2_re)
click_i, click_m = first_match(click_re)
if click_i <= rail_i:
    sys.exit("rail-click must follow rail n=2 (rail@%d click@%d)" % (
        rail_i, click_i))
click_id = click_m.group(1)
if click_id == rail_m.group(1):
    sys.exit("rail-click did not move focus (still %s)" % click_id)

click_o = first_order_after(click_i)
if click_o.group(5) != click_id:
    sys.exit("order after rail-click focus=%s want %s: %s" % (
        click_o.group(5), click_id, click_o.group(0)))
if click_o.group(1) != click_id:
    sys.exit("clicked cell 0 but order left id=%s want %s: %s" % (
        click_o.group(1), click_id, click_o.group(0)))

reo_i, reo_m = first_match_after(reorder_re, click_i)
if reo_m.group(1) != "0" or reo_m.group(2) != "1":
    sys.exit("HID drag must be 0->1, got %s->%s" % (
        reo_m.group(1), reo_m.group(2)))
reo_o = first_order_after(reo_i)
if (reo_o.group(1), reo_o.group(2)) != (click_o.group(2), click_o.group(1)):
    sys.exit("drag did not flip ids: click=%s drag=%s" % (
        click_o.group(0), reo_o.group(0)))
print("HID drag rail-click id=%s (was focus %s) flip %s" % (
    click_id, rail_m.group(1), reo_o.group(0)))
PY

vgate_file script2-launch.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-launch.txt <<'EOF'
wm
dui
echo rx-gotabwm-launch-ok
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-launch.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-space,c,a,l,c,return' \
    --input-chords-after 'gotabwm: present' \
    --script3 '$RUN_DIR/script3-launch.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-launch-ok' --timeout 300

vgate_assert 03 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 03 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 03 serial-contains 'gotabwm: registered'
vgate_assert 03 serial-contains 'gotabwm: tokens theme=dark bg=0x182026 surface=0x222d35 border=0x334155 accent=0x3b82f6'
vgate_assert 03 serial-contains 'gotabwm: present'
vgate_assert 03 serial-contains 'gotabwm: launcher emblem qoi 64x64'
vgate_assert 03 serial-contains 'gotabwm: launcher open n='
vgate_assert 03 serial-contains 'gotabwm: launcher filter q=calc n='
vgate_assert 03 serial-contains 'gotabwm: launcher exec GOCALC.ELF'
vgate_assert 03 serial-contains 'gotabwm: launcher dismiss'
vgate_assert 03 serial-contains 'gocalc: declare accepted'
vgate_assert 03 serial-contains 'gotabwm: close'
vgate_assert 03 serial-contains 'gotabwm OK'
vgate_assert 03 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 03 serial-contains 'rx-gotabwm-launch-ok'
vgate_assert 03 serial-absent 'NOTEPAD.ELF'
vgate_assert 03 serial-absent 'CALC.BIN'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
manifest = open(os.path.join(share, "APPS.TXT"), errors="replace").read()
bins = []
for line in manifest.splitlines():
    s = line.strip()
    if not s or s.startswith("#") or "|" not in s:
        continue
    bins.append(s.split("|", 1)[0].strip())
need = {"GOCALC.ELF", "NOTE.ELF", "GOEDIT.ELF", "GOFILES.ELF", "WEB.ELF",
        # M71f (#1565): the settings panel is the Go GOSET.ELF now, so the
        # catalogue must carry it -- and must NOT offer the retired Zig
        # SETTINGS.BIN (also in the forbidden list below), which is the whole
        # point of the deletion: no path may launch the dead panel.
        "GOSET.ELF",
        # M71g (#1566): TOP.BIN and SYSMON.BIN are retired into the one Go
        # GOTOP.ELF, so the catalogue must carry it and must NOT still offer
        # either Zig program (both in the forbidden list below) -- the
        # deletion cannot be quietly undone by an APPS.TXT row.
        "GOTOP.ELF",
        # M71h (#1567): and the image viewer, GOVIEW.ELF, in place of the
        # retired Zig VIEW.BIN. The catalogue is how a docked app is actually
        # reached, so this is where the deletion has to hold -- a leftover
        # manifest row would keep launching a binary that no longer exists.
        "GOVIEW.ELF"}
if not need.issubset(set(bins)):
    sys.exit("APPS.TXT missing daily set: %s" % sorted(need - set(bins)))
if "GOSH.ELF" not in bins and "GOTERM.ELF" not in bins:
    sys.exit("APPS.TXT missing GOSH.ELF and GOTERM.ELF")
for bad in ("NOTEPAD.ELF", "CALC.BIN", "CALC.ELF", "FILE.ELF", "DESKTOP.ELF",
            "SETTINGS.BIN", "TOP.BIN", "SYSMON.BIN", "VIEW.BIN"):
    if bad in bins:
        sys.exit("APPS.TXT still offers %s" % bad)
if "TABWM.BIN" in bins:
    # named fallback is allowed; dock=true is not
    for line in manifest.splitlines():
        if line.strip().startswith("TABWM.BIN") and "dock=true" in line:
            sys.exit("TABWM.BIN must not be a default dock target")
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def first_after(prefix):
    for i, line in enumerate(ser):
        if line.startswith(prefix):
            return i
    sys.exit("missing %s" % prefix)
open_i = first_after("gotabwm: launcher open n=")
filt_i = first_after("gotabwm: launcher filter q=calc n=")
exec_i = first_after("gotabwm: launcher exec GOCALC.ELF")
if filt_i <= open_i:
    sys.exit("filter must follow open (open@%d filter@%d)" % (open_i, filt_i))
if exec_i <= filt_i:
    sys.exit("exec must follow filter (filter@%d exec@%d)" % (filt_i, exec_i))
print("launcher open@%d filter@%d exec@%d catalog honest" % (
    open_i, filt_i, exec_i))
# Run 04 is seat-only and needs an empty strip on arrival: the seat's two-tab
# choreography in run 02 wrote SESSION.TABS (M62e `session write n=2`), and a
# later boot that restores it sets stripDone, which skips the single-tab close
# run 04's chord trigger waits on (observed 2026-09-21: run 03 and 04 both
# logged `session load n=2`). Drop it here, the same way go-wm-tabs clears it
# before its last boot.
stale = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
if os.path.exists(stale):
    os.remove(stale)
    print("cleared SESSION.TABS for run 04")
PY

# ---------------------------------------------------------------------------
# Run 04 (M71d / #1563, M48 BT1): the reopen chord.
#
# Seat-only, one client. Boot 03 proves the launcher; these boots prove BT1.
# The seat hosts GOCALC.ELF, whose single-tab path closes it after hostTicks
# (~16) — that close is what populates the reopen LIFO. The chord fires on
# that close marker and re-execs the recorded bin; the clone declares and
# joins as a fresh tab. The duplicate chord is run 05's, in its own boot: a
# same-batch ctrl-shift-d lands 0.25 s after the reopen (cv-input pacing,
# --input-chords-delay ignored) and before the clone's declare, where
# DuplicateFocused() is an honest no-op (measured 2026-09-24). Three Go
# runtimes (seat + two clients) is the #1449 wall, which is why this is
# seat-only and not the GOEDIT+GOTERM pair.
vgate_file script-bt1.txt <<'EOF'
set GOMAXPROCS=1
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-bt1.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
EOF

vgate_file script3-bt1.txt <<'EOF'
wm
dui
echo rx-gotabwm-bt1-ok
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --via-virtio \
    --script '$RUN_DIR/script-bt1.txt' \
    --script2 '$RUN_DIR/script2-bt1.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-t' \
    --input-chords-after 'gotabwm: tab close id=' \
    --script3 '$RUN_DIR/script3-bt1.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-bt1-ok' --timeout 300

vgate_assert 04 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 04 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 04 serial-contains 'gotabwm: registered'
vgate_assert 04 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 04 serial-contains 'gotabwm: tab open id='
# BT1: the chord outcome names the re-exec'd executable.
vgate_assert 04 serial-contains 'gotabwm: reopen GOCALC.ELF'
vgate_assert 04 serial-absent 'gotabwm: reopen missing '
vgate_assert 04 serial-contains 'gotabwm: close'
vgate_assert 04 serial-contains 'gotabwm OK'
vgate_assert 04 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 04 serial-contains 'rx-gotabwm-bt1-ok'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_after(prefix, start=0):
    for i in range(start, len(ser)):
        if ser[i].startswith(prefix):
            return i
    sys.exit("missing %s after %d" % (prefix, start))

close_i = first_after("gotabwm: tab close id=")
reopen_i = first_after("gotabwm: reopen GOCALC.ELF")
if reopen_i <= close_i:
    sys.exit("reopen must follow the close that recorded the bin (close@%d reopen@%d)" %
             (close_i, reopen_i))
# The seat's own markers are the authoritative evidence: the re-exec'd app
# declared over WM_RPC and joined the strip as a fresh tab.
# NOT asserted: `exec: loaded GOCALC.ELF`, which is the MONITOR's exec-command
# echo. The seat's vi.Exec goes through the ADR 0007 slot-28 syscall and does
# not print it (measured 2026-09-21: exactly one such line, the script2 exec).
opens = [i for i, l in enumerate(ser) if l.startswith("gotabwm: tab open id=")]
if len(opens) < 2:
    sys.exit("want 2 tab opens (initial + reopen), got %d" % len(opens))
if len([i for i in opens if i > reopen_i]) < 1:
    sys.exit("want an open after the reopen chord (reopen@%d opens=%s)" % (reopen_i, opens))
# Each re-exec is a real process that runs to a clean exit, not a fake ack.
# Substring match, the house serial-contains semantic: teardown-time console
# output can interleave a byte fragment onto the marker's line (measured
# 2026-09-24: `40gocalc OK` while tasks were tearing down). The marker itself
# is the evidence; an exact-line check rejected a real clean exit.
exits = [i for i, l in enumerate(ser) if "gocalc OK" in l]
if len(exits) < 2:
    sys.exit("want 2 GOCALC processes to exit cleanly, got %d" % len(exits))
print("BT1 reopen: close@%d reopen@%d; %d tab opens, %d clean GOCALC exits" % (
    close_i, reopen_i, len(opens), len(exits)))
PY

# ---------------------------------------------------------------------------
# Run 05 (M71d / #1563, M48 BT1): the duplicate chord.
#
# Same boot shape, one client. The chord fires on the client's own tab-open
# marker -- the focused tab exists and carries its bin -- and ctrl-shift-d
# re-execs it; the clone declares and the strip reads n=2 with the clone
# focused. (Run 04 carries the reopen chord; see the transport note above for
# why one batch cannot carry both.) The single-tab countdown window is
# hostTicks (~16 ticks) and the clone's declare lands ~5 ticks after the chord
# (measured 2026-09-24, by marker spacing), well inside it; seeing two tabs
# latches stripSawTwo so the countdown never fires (compositeTick).
vgate_file script3-bt1-dup.txt <<'EOF'
wm
dui
echo rx-gotabwm-bt1-dup-ok
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio \
    --script '$RUN_DIR/script-bt1.txt' \
    --script2 '$RUN_DIR/script2-bt1.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-d' \
    --input-chords-after 'gotabwm: tab open id=' \
    --script3 '$RUN_DIR/script3-bt1-dup.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-bt1-dup-ok' --timeout 300

vgate_assert 05 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 05 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 05 serial-contains 'gotabwm: registered'
vgate_assert 05 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 05 serial-contains 'gotabwm: tab open id='
# BT1: the chord outcome names the re-exec'd executable.
vgate_assert 05 serial-contains 'gotabwm: duplicate GOCALC.ELF'
vgate_assert 05 serial-absent 'gotabwm: duplicate missing '
vgate_assert 05 serial-contains 'gotabwm: rail n=2 focus='
vgate_assert 05 serial-contains 'gotabwm: close'
vgate_assert 05 serial-contains 'gotabwm OK'
vgate_assert 05 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 05 serial-contains 'rx-gotabwm-bt1-dup-ok'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
vgate_assert 05 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_after(prefix, start=0):
    for i in range(start, len(ser)):
        if ser[i].startswith(prefix):
            return i
    sys.exit("missing %s after %d" % (prefix, start))

open_i = first_after("gotabwm: tab open id=")
dup_i = first_after("gotabwm: duplicate GOCALC.ELF")
if dup_i <= open_i:
    sys.exit("duplicate must follow the focused tab's open (open@%d dup@%d)" %
             (open_i, dup_i))
opens = [i for i, l in enumerate(ser) if l.startswith("gotabwm: tab open id=")]
if len(opens) < 2:
    sys.exit("want 2 tab opens (initial + clone), got %d" % len(opens))
if len([i for i in opens if i > dup_i]) < 1:
    sys.exit("want an open after the duplicate chord (dup@%d opens=%s)" % (dup_i, opens))
# Each re-exec is a real process that runs to a clean exit, not a fake ack.
# Substring match, the house serial-contains semantic: teardown-time console
# output can interleave a byte fragment onto the marker's line (measured
# 2026-09-24: `40gocalc OK` while tasks were tearing down). The marker itself
# is the evidence; an exact-line check rejected a real clean exit.
exits = [i for i, l in enumerate(ser) if "gocalc OK" in l]
if len(exits) < 2:
    sys.exit("want 2 GOCALC processes to exit cleanly, got %d" % len(exits))
# The clone put a SECOND tab on the strip: the rail is n=2 with the clone focused.
if not any(l.startswith("gotabwm: rail n=2 focus=") and i > dup_i for i, l in enumerate(ser)):
    sys.exit("duplicate left no n=2 rail after the chord")
print("BT1 dup: open@%d duplicate@%d; %d tab opens, %d clean GOCALC exits" % (
    open_i, dup_i, len(opens), len(exits)))
PY

# ---------------------------------------------------------------------------
# Run 06 (M79b / #1705): the close-x button and hover highlight.
#
# Same boot shape as run 01 (two clients: GOEDIT + GOTERM). The pointer phase
# is two steps on the rail: a motion over cell 0 (the hover tint + entry
# marker) and a press/release on cell 0's close-x (the cell's rightmost 16 px
# at cellW=640: x in [624,640)). The close-x closes GOEDIT with NO focus
# change first -- no rail-click, no tab focus -- and the rail marker drops to
# n=1 with GOTERM keeping focus. The 2-step phase sits well inside the
# choreography hold (hidChordHold=32 ticks; run 01 fits a click, a type-in
# and a chord batch in the same window).
#
# The boot drops any stale SESSION.TABS first: vgate_setup_python runs ONCE
# per spec (vgate.sh runs every setup body before the run loop), so the M62e
# cleanup cannot protect a later boot. Run 05's two-tab chain writes the
# session (`session write n=2`), and without the drop this boot restored it
# (measured 2026-09-24: `session load n=2` titles=Calc,Calc -> the strip read
# n=4 with the restored placeholders, the `rail n=2` trigger never fired, and
# the pointer phase never ran). `vf rm` is the go-wm-seat run 05 pattern.
vgate_file script-m79b.txt <<'EOF'
set GOMAXPROCS=1
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio \
    --script '$RUN_DIR/script-m79b.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '320,10;632,10,d;632,10,u' \
    --pointer-virtio-after 'gotabwm: rail n=2' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-ok' --timeout 300

vgate_assert 06 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 06 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 06 serial-contains 'gotabwm: registered'
vgate_assert 06 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 06 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 06 serial-contains 'gotabwm: rail n=2'
# M79b: hover names the cell and the close-x closes that same tab with no
# focus change first; the rail marker drops to n=1.
vgate_assert 06 serial-contains 'gotabwm: rail-hover id='
vgate_assert 06 serial-contains 'gotabwm: tab close id='
vgate_assert 06 serial-contains 'gotabwm: rail n=1'
vgate_assert 06 serial-absent 'gotabwm: rail-click id='
vgate_assert 06 serial-contains 'gotabwm: close'
vgate_assert 06 serial-contains 'gotabwm OK'
vgate_assert 06 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 06 serial-contains 'rx-gotabwm-hid-ok'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'
vgate_assert 06 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_after(prefix, start=0):
    for i in range(start, len(ser)):
        if ser[i].startswith(prefix):
            return i
    sys.exit("missing %s after %d" % (prefix, start))

hover_i = first_after("gotabwm: rail-hover id=")
close_i = first_after("gotabwm: tab close id=")
if close_i <= hover_i:
    sys.exit("the close-x must follow the hover (hover@%d close@%d)" % (hover_i, close_i))
hover_id = ser[hover_i].split("id=")[1]
close_id = ser[close_i].split("id=")[1]
if hover_id != close_id:
    sys.exit("hover named id=%s but the close-x closed id=%s" % (hover_id, close_id))
# Hit-test honesty: between the hover and the close there is no focus change
# and no rail click -- the close-x closes a BUTTON, not a cell.
for i in range(hover_i, close_i):
    if ser[i].startswith(("gotabwm: rail-click id=", "gotabwm: tab focus id=", "gotabwm: host focus id=")):
        sys.exit("focus changed before the close-x (line %d: %s)" % (i, ser[i]))
rail_i = -1
for i in range(close_i, len(ser)):
    if ser[i].startswith("gotabwm: rail n=1 focus="):
        rail_i = i
        break
if rail_i < 0:
    sys.exit("the rail marker never dropped to n=1 after the close-x")
print("M79b: hover@%d id=%s close-x@%d rail n=1@%d" % (hover_i, hover_id, close_i, rail_i))
PY

# ---------------------------------------------------------------------------
# Run 07 (M79f / #1717): Ctrl+Tab and Ctrl+2 across a three-tab strip.
#
# The last declared client (GOCALC) owns focus on arrival, so Ctrl+Tab must
# wrap to rail cell 1 (GOEDIT) and Ctrl+2 must then focus cell 2 (GOTERM).
# Four GOMAXPROCS=1 Go runtimes consume the M65 task budget exactly; the
# runner starts this phase at rail n=3 before the demo choreography can close.
vgate_file script-m79f.txt <<'EOF'
set GOMAXPROCS=1
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-m79f.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF
exec GOTERM.ELF
exec GOCALC.ELF
EOF

vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --via-virtio \
    --script '$RUN_DIR/script-m79f.txt' \
    --script2 '$RUN_DIR/script2-m79f.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-tab,ctrl-2' \
    --input-chords-after 'gotabwm: rail n=3' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-ok' --timeout 420

vgate_assert 07 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 07 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 07 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 07 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 07 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 07 serial-contains 'gotabwm: registered'
vgate_assert 07 serial-contains 'gotabwm: rail n=3'
vgate_assert 07 serial-contains 'gotabwm: alt-tab id='
vgate_assert 07 serial-contains 'gotabwm: close'
vgate_assert 07 serial-contains 'gotabwm OK'
vgate_assert 07 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 07 serial-contains 'rx-gotabwm-hid-ok'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'exited status=139'
vgate_assert 07 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_after(prefix, start=0):
    for i in range(start + 1, len(ser)):
        if ser[i].startswith(prefix):
            return i
    sys.exit("missing %s after %d" % (prefix, start))

def first_match(rx):
    for i, line in enumerate(ser):
        m = rx.match(line)
        if m:
            return i, m
    sys.exit("missing /%s/" % rx.pattern)

def first_order_after(start):
    rx = re.compile(
        r"^gotabwm: order ids=(\d+),(\d+),(\d+) pin=(\d),(\d),(\d) focus=(\d+)$")
    for i in range(start + 1, len(ser)):
        m = rx.match(ser[i])
        if m:
            return i, m
    sys.exit("no order after index %d" % start)

edit_i, edit_m = first_match(re.compile(r"^goedit: open id=(\d+)$"))
term_i, term_m = first_match(re.compile(r"^goterm: open id=(\d+)$"))
calc_i, calc_m = first_match(re.compile(r"^gocalc: open id=(\d+)$"))
rail_i, rail_m = first_match(re.compile(r"^gotabwm: rail n=3 focus=(\d+)$"))
wrap_i = first_after("gotabwm: alt-tab id=", rail_i)
if wrap_i <= max(edit_i, term_i, calc_i):
    sys.exit("M79f chords must follow all three client opens")
# The rail's cell order is the SEAT's host order — the three execs race,
# so the clients' own open-marker order need not match it (observed
# 2026-10-18 under load: declares landed 4,5,3 while the client markers
# printed 3,4,5). Read the seat's tab-open chain instead.
ids = []
for line in ser:
    m = re.match(r"^gotabwm: tab open id=(\d+)$", line)
    if m:
        ids.append(int(m.group(1)))
    if len(ids) == 3:
        break
if len(set(ids)) != 3:
    sys.exit("seat tab-open chain is not three distinct ids: %s" % (ids,))
ids = tuple(ids)
start = ids.index(int(rail_m.group(1)))
want_wrap = ids[(start + 1) % len(ids)]
# Ctrl+2 selects the second RAIL cell — under the MRU rail that is the
# wrap order's second entry, not the open order's.
want_direct = None  # resolved after the wrap order is read

wrap_o_i, wrap_o = first_order_after(wrap_i)
direct_i = first_after("gotabwm: alt-tab id=", wrap_i)
direct_o_i, direct_o = first_order_after(direct_i)
if not (rail_i < wrap_i < wrap_o_i < direct_i < direct_o_i):
    sys.exit("chord marker/order chain out of order")
# The rail now MRU-orders: a wrap chord pulls the focused cell to the
# front, a direct chord focuses without reordering. The contract below
# checks the observed orders against exactly that rule, not the older
# tab-open-order invariant.
wrap_order = tuple(int(wrap_o.group(i)) for i in range(1, 4))
want_order = (want_wrap,) + tuple(i for i in ids if i != want_wrap)
if wrap_order != want_order:
    sys.exit("wrap chord order: got %s want %s (focused-first MRU)" %
             (wrap_order, want_order))
direct_order = tuple(int(direct_o.group(i)) for i in range(1, 4))
if direct_order != wrap_order:
    sys.exit("direct chord reordered the rail: got %s want %s" %
             (direct_order, wrap_order))
want_direct = wrap_order[1]
if int(wrap_o.group(7)) != want_wrap:
    sys.exit("Ctrl+Tab focused %s want next rail cell %s" % (
        wrap_o.group(7), want_wrap))
if int(direct_o.group(7)) != want_direct:
    sys.exit("Ctrl+2 focused %s want second rail cell %s" % (
        direct_o.group(7), want_direct))
print("M79f: focus %s --ctrl-tab--> %s --ctrl-2--> %s across three tabs" % (
    rail_m.group(1), wrap_o.group(7), direct_o.group(7)))
PY

# ---------------------------------------------------------------------------
# Run 08 (M82c / #1770): the global shortcuts registry and the conflict
# fixture.
#
# The monitor seeds GOTABWM.CHORDCONFLICT before the seat execs: the prologue
# validates the shipped table (fail-closed), feeds the checker the
# deliberately conflicting fixture — FIXTURE.ELF claiming the seat's
# palette chord (ctrl+shift+p; pin's home until M121a re-homed it to
# ctrl-shift-n) at the seat's own dispatch point — prints the full
# named refusal, then the whole table (one `gotabwm: chord` line per row)
# and the summary line. The seat carries on with the UNTOUCHED shipped
# table: the fixture is a refusal exercise, not a reconfiguration. GOSET
# then opens its shortcuts view with the panel's own registered chord
# (ctrl+shift+h, a GOSET.ELF app row — re-bound from ctrl+shift+s when
# M81g #1767 landed the seat's snapshot arm on that chord first) — the
# registry a user can actually look at. Two Go runtimes is inside the
# #1449 wall; GOMAXPROCS=1.
vgate_file script-m82c.txt <<'EOF'
set GOMAXPROCS=1
write GOTABWM.CHORDCONFLICT conflict
wm
exec GOTABWM.ELF
EOF

vgate_file script2-m82c.txt <<'EOF'
dui focus 0
exec GOSET.ELF
EOF

vgate_file script3-m82c.txt <<'EOF'
wm
dui
echo rx-gotabwm-chords-ok
EOF

vgate_run 08 -- \
    --screen '$RUN_DIR/screen-08' \
    --via-virtio \
    --script '$RUN_DIR/script-m82c.txt' \
    --script2 '$RUN_DIR/script2-m82c.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-h' \
    --input-chords-after 'goset: ready ' \
    --script3 '$RUN_DIR/script3-m82c.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-chords-ok' --timeout 300

vgate_assert 08 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 08 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 08 serial-contains 'gotabwm: registered'
# M82c: the checker refused the conflicting fixture with the NAMED error —
# chord, dispatch point, both owners, one sentence.
vgate_assert 08 serial-contains 'gotabwm: chords refused chord conflict: ctrl+shift+p at seat owned by seat and FIXTURE.ELF'
# The loud failure (the checker accepting the fixture) must never print.
vgate_assert 08 serial-absent 'gotabwm: chords fixture accepted'
# The registry table itself, in the guest: a frozen kernel chrome row, the
# seat rows the fixture fought over and that M81g added (the snapshot
# arm), and two app rows (GOEDIT's save chord, and the GOSET chord that
# just drove this boot's shortcuts view).
vgate_assert 08 serial-contains 'gotabwm: chord ctrl+shift+k owner=kernel scope=kernel-terminal'
vgate_assert 08 serial-contains 'gotabwm: chord ctrl+shift+p owner=seat scope=seat'
vgate_assert 08 serial-contains 'gotabwm: chord ctrl+s owner=GOEDIT.ELF scope=app/GOEDIT.ELF'
vgate_assert 08 serial-contains 'gotabwm: chord ctrl+shift+s owner=seat scope=seat'
vgate_assert 08 serial-contains 'gotabwm: chord ctrl+shift+h owner=GOSET.ELF scope=app/GOSET.ELF'
# The one-seat probe still ran after the prologue; the seat still came up.
vgate_assert 08 serial-contains 'gotabwm: seat-taken'
vgate_assert 08 serial-contains 'dogfood: seat'
# The GO panel's shortcuts view, opened with its registered chord.
vgate_assert 08 serial-contains 'exec: loaded GOSET.ELF'
vgate_assert 08 serial-contains 'goset: open id='
vgate_assert 08 serial-contains 'goset: shortcuts n='
vgate_assert 08 serial-contains 'gotabwm: close'
vgate_assert 08 serial-contains 'gotabwm OK'
vgate_assert 08 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 08 serial-contains 'rx-gotabwm-chords-ok'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-absent 'exited status=139'
vgate_assert 08 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_after(prefix, start=0):
    for i in range(start, len(ser)):
        if ser[i].startswith(prefix):
            return i
    sys.exit("missing %s" % prefix)

reg_i = first_after("gotabwm: registered")
ref_i = first_after(
    "gotabwm: chords refused chord conflict: ctrl+shift+p at seat owned by seat and FIXTURE.ELF")
sum_i = first_after("gotabwm: chords n=")
if not (reg_i < ref_i < sum_i):
    sys.exit("prologue out of order (registered@%d refused@%d summary@%d)" % (
        reg_i, ref_i, sum_i))
m = re.match(r"^gotabwm: chords n=(\d+) seat=(\d+) kernel=(\d+) app=(\d+)$", ser[sum_i])
if not m:
    sys.exit("summary line malformed: %s" % ser[sum_i])
n, seat, kernel, app = map(int, m.groups())
if not (n == seat + kernel + app and min(seat, kernel, app) > 0):
    sys.exit("summary counts inconsistent: %s" % ser[sum_i])

# The dump is the whole table: one line per row, and no (chord, scope) pair
# twice — the checker's invariant, observed on the serial.
rows = [l for l in ser if l.startswith("gotabwm: chord ")]
if len(rows) != n:
    sys.exit("dumped %d rows for n=%d" % (len(rows), n))
seen = set()
for r in rows:
    body = r[len("gotabwm: chord "):]
    chord = body.split(" owner=")[0]
    scope = body.split(" scope=")[1].split(" ")[0]
    if (chord, scope) in seen:
        sys.exit("two rows for %s at %s" % (chord, scope))
    seen.add((chord, scope))

# The GO panel's view: opened after the refusal, and its size is the table.
goset_i = first_after("goset: open id=")
view_i = first_after("goset: shortcuts n=")
if view_i <= goset_i:
    sys.exit("the shortcuts view must follow the panel's open (open@%d view@%d)" % (
        goset_i, view_i))
vm = re.search(r"goset: shortcuts n=(\d+)", ser[view_i])
if int(vm.group(1)) != n:
    sys.exit("GOSET rendered n=%s, seat dumped n=%d" % (vm.group(1), n))
print("M82c: refused@%d summary@%d n=%d (%d seat, %d kernel, %d app); "
      "%d dumped rows all unique per (chord, scope); GOSET view@%d" % (
          ref_i, sum_i, n, seat, kernel, app, len(rows), view_i))
PY

# ---------------------------------------------------------------------------
# Run 09 (M83d2 / #1786): the persisted DE table at the measured kernel path.
#
# The monitor persists keyboard_layout=de before GOTABWM starts; the standard
# kind-1 app-key path then translates HID Y/Z positions and the semicolon
# position to Unicode in the kernel, and GOEDIT saves the resulting UTF-8.
# Kind-21 remains raw usage+flags for the seat. GOSET and reboot persistence
# are covered by go-wm-default.
vgate_file script-m83d2.txt <<'EOF'
set GOMAXPROCS=1
vf rm SESSION.TABS
settings set keyboard_layout de
wm
exec GOTABWM.ELF
EOF

vgate_run 09 -- \
    --screen '$RUN_DIR/screen-09' \
    --via-virtio \
    --script '$RUN_DIR/script-m83d2.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '320,10,c' \
    --pointer-virtio-after 'gotabwm: rail n=2' \
    --input-chords 'y,z,Y,;,ctrl-s' \
    --input-chords-after 'gotabwm: rail-click id=' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-ok' --timeout 300

vgate_assert 09 serial-contains 'settings: keyboard_layout=de (persisted)'
vgate_assert 09 serial-contains 'gotabwm: rail n=2'
vgate_assert 09 serial-contains 'gotabwm: rail-click id='
vgate_assert 09 serial-contains 'goedit: dirty'
vgate_assert 09 serial-contains 'goedit: saved /host/EDIT/SEED.TXT'
vgate_assert 09 serial-contains 'rx-gotabwm-hid-ok'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 serial-absent 'exited status=139'
vgate_assert 09 python <<'PY'
import os, sys
path = os.path.join(os.environ["VG_SHARE"], "EDIT", "SEED.TXT")
got = open(path, "rb").read()
want = "seed-line\nXYZzyZö".encode("utf-8")
if got != want:
    sys.exit("DE kernel keymap saved %r, want %r" % (got, want))
print("DE keymap: physical y,z,Y,; arrived as z,y,Z,ö in GOEDIT and saved UTF-8 byte-exactly")
PY

# ---------------------------------------------------------------------------
# Run 10 (M83e / #1778): dead keys under the persisted DE table.
#
# Same boot as run 09. The kernel delivers the DE acute key (usage 0x2e, the
# runner's `=`) with no symbol and the circumflex key (0x35, the runner's
# backtick) as a literal '^'; GOEDIT decides "dead" by (layout, usage) and
# composes in the app. The chords are one of each outcome:
#   =,e        acute + e            -> é      (composed)
#   `,o        circumflex + o       -> ô      (composed)
#   =,x        acute + x            -> ´x     (stray: both typed, none lost)
#   =,space    acute + space        -> ´      (the bare accent)
# `goedit: stage <accent>` is printed after the frame that shows the pending
# accent was presented, so it is the receipt the staging buffer was on
# screen. The grave (Shift+acute) has no runner token, so the layout and
# editor host tests carry it. The share persists from run 09, so the file is
# checked as a seed plus an exact appended tail.
vgate_run 10 -- \
    --screen '$RUN_DIR/screen-10' \
    --via-virtio \
    --script '$RUN_DIR/script-m83d2.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '320,10,c' \
    --pointer-virtio-after 'gotabwm: rail n=2' \
    --input-chords '=,e,`,o,=,x,=,space,ctrl-s' \
    --input-chords-after 'gotabwm: rail-click id=' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-ok' --timeout 300

vgate_assert 10 serial-contains 'settings: keyboard_layout=de (persisted)'
vgate_assert 10 serial-contains 'goedit: layout de'
vgate_assert 10 serial-contains 'gotabwm: rail-click id='
vgate_assert 10 serial-count 'goedit: stage acute' 3
vgate_assert 10 serial-contains 'goedit: stage circumflex'
vgate_assert 10 serial-contains 'goedit: dirty'
vgate_assert 10 serial-contains 'goedit: saved /host/EDIT/SEED.TXT'
vgate_assert 10 serial-contains 'rx-gotabwm-hid-ok'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 serial-absent 'exited status=139'
vgate_assert 10 python <<'PY'
import os, sys
path = os.path.join(os.environ["VG_SHARE"], "EDIT", "SEED.TXT")
got = open(path, "rb").read()
tail = "\u00e9\u00f4\u00b4x\u00b4".encode("utf-8")
if not got.startswith(b"seed-line\n"):
    sys.exit("seed lost: %r" % got)
if not got.endswith(tail) or got.count(tail) != 1:
    sys.exit("dead keys saved %r, want the run to end in %r (e-acute, o-circumflex, "
             "stray acute + x, bare acute)" % (got, tail))
print("dead keys: =e -> e-acute, `o -> o-circumflex, =x -> acute+x, =space -> acute; "
      "%d bytes saved UTF-8 byte-exactly" % len(got))
PY

# M87a: keep every prior rail/drag/close boot above. The live menu boots
# below have no demo choreography and no keyboard launch stand-ins.
vgate_file script-m87.txt <<'EOF'
set GOMAXPROCS=1
vf rm SESSION.TABS
vf rm GOTABWM.DEMO
vf rm GOTABWM.CHORDCONFLICT
settings set keyboard_layout us
wm
exec GOTABWM.ELF
EOF

vgate_file script2-m87-edit.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF /host/EDIT/M87.TXT
EOF

vgate_file script2-m87-shell.txt <<'EOF'
dui focus 0
exec GOSH.ELF
EOF

vgate_file script3-m87.txt <<'EOF'
dui
echo rx-gotabwm-menu-ok
EOF

# Raw kind-4 pixels are the presented GUEST scanout, not the host VM view.
# Three pinned glyph masks distinguish real prompt/row text from fills, and
# a colour-count probe names the emblem raster (the #2054 strip's header:
# 'W' of "Where do you want to go today?", row0 '6' of "64-bit Calc", row4
# 'T' of "Terminal" — all docked at the strip's left edge). Save a PNG of
# those exact guest pixels as small local review evidence.
vgate_file menu-glyphs.py <<'PY'
import os, pathlib, struct, sys, zlib
raw = open(sys.argv[1], "rb").read()
W, H = 1280, 720
if len(raw) != W * H * 4:
    sys.exit("missing full guest scanout")
glyphs = [
    ("prompt W", 8, 88, [0x63, 0x63, 0x63, 0x6b, 0x7f, 0x77, 0x63, 0]),
    ("64-bit Calc 6", 14, 146, [0x1c, 0x06, 3, 0x1f, 0x33, 0x33, 0x1e, 0]),
    ("Terminal T", 14, 242, [0x3f, 0x2d, 0x0c, 0x0c, 0x0c, 0x0c, 0x1e, 0]),
]
for name, x, y, rows in glyphs:
    def pixel(dx, dy):
        p = ((y + dy) * W + x + dx) * 4
        return raw[p:p+3]
    # Ordinary windows have the existing kernel fade-in. The first
    # presented frame may be dimmed, but must contain the SAME exact
    # foreground/background glyph mask, with visible contrast.
    background = pixel(7, 7)
    first = next((dx, dy) for dy, bits in enumerate(rows)
                 for dx in range(8) if bits & (1 << dx))
    ink = pixel(*first)
    if min(abs(a-b) for a, b in zip(ink, background)) < 32:
        sys.exit("%s glyph has no readable contrast" % name)
    for dy, bits in enumerate(rows):
        for dx in range(8):
            want = ink if bits & (1 << dx) else background
            if pixel(dx, dy) != want:
                sys.exit("%s glyph mismatch at %d,%d" % (name, dx, dy))
# The emblem slot (centred in the strip's header) must hold the mascot
# raster, not the bordered "SB" fallback: a flat box has a handful of
# colours, the real raster has dozens. Fade-in dimming shifts every colour
# together, so distinctness survives it.
seen = set()
for dy in range(16, 80):
    for dx in range(99, 163):
        seen.add(raw[(dy * W + dx) * 4: (dy * W + dx) * 4 + 3])
if len(seen) < 12:
    sys.exit("emblem slot holds %d colours, not the mascot raster" % len(seen))
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
rows = bytearray()
for y in range(H):
    rows.append(0)
    for x in range(W):
        p = (y * W + x) * 4
        rows.extend((raw[p+2], raw[p+1], raw[p]))
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
out = "artifacts/go-wm-hid-menu-%s%s.png" % (
    pathlib.Path(sys.argv[1]).name.split("-")[1], os.environ.get("VIRELAI_GATE_SUFFIX", ""))
open(out, "wb").write(png)
print("guest strip glyph masks + emblem raster match; saved " + out)
PY

# Existing editor -> Apps button -> emblem press (no exec) -> row0 named
# Calculator. Held motion/release crosses the rail/content after exec and
# stays chrome. (#2054 strip coords: button at 272,702; the emblem is
# (99..163,16..80); row0 sits at y=140.)
vgate_run 11 -- \
    --screen '$RUN_DIR/screen-11' --via-virtio --cvc-snap \
    --snapshot-after 'gotabwm: launcher presented' \
    --snapshot-out '$RUN_DIR/menu-11' \
    --script '$RUN_DIR/script-m87.txt' \
    --script2 '$RUN_DIR/script2-m87-edit.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '272,702,d;272,702,u;132,50,d;800,650;800,650,u;20,150,d;960,10;800,400,u' \
    --pointer-virtio-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-m87.txt' \
    --script3-after 'gocalc: declare accepted' --script3-delay 8 \
    --script-expect 'rx-gotabwm-menu-ok' --timeout 300
vgate_assert 11 serial-contains 'gotabwm: mode live'
vgate_assert 11 serial-contains 'goedit: declare accepted'
vgate_assert 11 serial-contains 'gotabwm: launcher focus sink='
vgate_assert 11 serial-contains 'gotabwm: launcher presented'
vgate_assert 11 serial-exact 'gotabwm: launcher exec GOCALC.ELF' 1
vgate_assert 11 serial-contains 'gocalc: declare accepted'
vgate_assert 11 serial-absent 'gotabwm: launcher missing '
vgate_assert 11 serial-absent 'gotabwm: reorder '
vgate_assert 11 serial-absent 'dui: term sel '
vgate_assert 11 serial-absent '[EXC] parking:'
vgate_assert 11 serial-absent 'exited status=139'
vgate_assert 11 snapshot 'menu-11-*.raw' <<'PY'
import pathlib, sys
exec((pathlib.Path(sys.argv[1]).parent / "menu-glyphs.py").read_text())
PY
vgate_assert 11 python <<'PY'
import os, re, sys
s = open(os.environ["VG_SER"], errors="replace").read()
opened = re.search(r'gocalc: open id=(\d+)', s)
if not opened:
    sys.exit("Calculator never opened a real window")
focus = 'gotabwm: host focus id=' + opened[1]
launch = s.index('gotabwm: launcher exec GOCALC.ELF')
if focus not in s[launch:]:
    sys.exit("launched Calculator did not take real hosted focus")
if s.count("gotabwm: launcher exec ") != 1:
    sys.exit("header/held/release caused another exec")
print("pointer Calculator declared and focused; header did not exec")
PY

# Existing GOSH -> pointer-open -> named Terminal row (manifest index 4).
# The launched app must attach a tty, present its prompt, and run a command
# with an actual successful shell status. The existing cv-input ASCII
# transport does not map '>'; do not replace typing with a monitor script.
vgate_run 12 -- \
    --screen '$RUN_DIR/screen-12' --via-virtio --cvc-snap \
    --snapshot-after 'gotabwm: launcher presented' \
    --snapshot-out '$RUN_DIR/menu-12' \
    --script '$RUN_DIR/script-m87.txt' \
    --script2 '$RUN_DIR/script2-m87-shell.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '272,702,d;272,702,u;20,246,d;960,10;800,400,u' \
    --pointer-virtio-after 'gosh: declare accepted' \
    --input-string $'echo m87-terminal\n' \
    --input-string-after 'goterm: prompt' \
    --script3 '$RUN_DIR/script3-m87.txt' \
    --script3-after 'goterm: done status=0' --script3-delay 8 \
    --script-expect 'rx-gotabwm-menu-ok' --timeout 300
vgate_assert 12 serial-contains 'gotabwm: mode live'
vgate_assert 12 serial-contains 'gotabwm: launcher focus sink='
vgate_assert 12 serial-contains 'gotabwm: launcher presented'
vgate_assert 12 serial-exact 'gotabwm: launcher exec GOTERM.ELF' 1
vgate_assert 12 serial-contains 'goterm: declare accepted'
vgate_assert 12 serial-contains 'goterm: attached'
vgate_assert 12 serial-contains 'goterm: prompt'
vgate_assert 12 serial-contains 'goterm: line echo m87-terminal'
vgate_assert 12 serial-contains 'goterm: done status=0'
vgate_assert 12 serial-absent 'dui: term sel '
vgate_assert 12 serial-absent 'gotabwm: reorder '
vgate_assert 12 serial-absent '[EXC] parking:'
vgate_assert 12 serial-absent 'exited status=139'
vgate_assert 12 snapshot 'menu-12-*.raw' <<'PY'
import pathlib, sys
exec((pathlib.Path(sys.argv[1]).parent / "menu-glyphs.py").read_text())
PY
vgate_assert 12 python <<'PY'
import os, re, sys
s = open(os.environ["VG_SER"], errors="replace").read()
opened = re.search(r'goterm: open id=(\d+)', s)
if not opened:
    sys.exit("Terminal never opened a real window")
launch = s.index('gotabwm: launcher exec GOTERM.ELF')
if 'gotabwm: host focus id=' + opened[1] not in s[launch:]:
    sys.exit("launched Terminal never took hosted focus")
if s.count("gotabwm: launcher exec ") != 1:
    sys.exit("Terminal gesture caused more than one exec")
print("pointer Terminal declared, focused, attached, prompted and ran the receipt command")
PY

# The dual-path negative: pointer-open while GOEDIT owns focus, filter with
# ordinary HID keys, header press (no exec), outside press (no underlying
# click), restore the old editor and SAVE it. The bytes, not consumed=true,
# prove the old app did not receive the filter text.
vgate_run 13 -- \
    --screen '$RUN_DIR/screen-13' --via-virtio \
    --script '$RUN_DIR/script-m87.txt' \
    --script2 '$RUN_DIR/script2-m87-edit.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '272,702,d;272,702,u;132,50,d;132,50,u;800,650,d;960,10;800,400,u' \
    --pointer-virtio-after 'goedit: present' \
    --input-string 'calc' --input-string-after 'gotabwm: launcher open n=' \
    --input-chords 'ctrl-s' --input-chords-after 'gotabwm: launcher restore id=' \
    --script3 '$RUN_DIR/script3-m87.txt' \
    --script3-after 'goedit: saved /host/EDIT/M87.TXT n=10' --script3-delay 8 \
    --script-expect 'rx-gotabwm-menu-ok' --timeout 300
vgate_assert 13 serial-contains 'gotabwm: launcher focus sink='
# M191b: n=3 — the manifest row, the /host/GOCALC.ELF filename hit, and
# the M165f hand-off row this face now carries too.
vgate_assert 13 serial-contains 'gotabwm: launcher filter q=calc n=3'
vgate_assert 13 serial-contains 'gotabwm: launcher restore id='
vgate_assert 13 serial-contains 'goedit: saved /host/EDIT/M87.TXT n=10'
vgate_assert 13 share-equals EDIT/M87.TXT $'seed-line\n'
vgate_assert 13 serial-absent 'goedit: dirty'
vgate_assert 13 serial-absent 'gotabwm: launcher exec '
vgate_assert 13 serial-absent 'gotabwm: rail-click id='
vgate_assert 13 serial-absent 'gotabwm: reorder '
vgate_assert 13 serial-absent 'dui: term sel '
vgate_assert 13 serial-absent '[EXC] parking:'
vgate_assert 13 serial-absent 'exited status=139'
vgate_assert 13 python <<'PY'
import os, re, sys
s = open(os.environ["VG_SER"], errors="replace").read()
edit = re.search(r'goedit: open id=(\d+)', s)
sink = re.search(r'gotabwm: launcher focus sink=(\d+)', s)
restore = re.search(r'gotabwm: launcher restore id=(\d+)', s)
if not edit or not sink or not restore or edit[1] != restore[1] or sink[1] == edit[1]:
    sys.exit("menu did not own a distinct sink and restore the former live editor")
if not (sink.start() < s.index('gotabwm: launcher filter q=calc') < restore.start()
        < s.index('goedit: saved /host/EDIT/M87.TXT n=10')):
    sys.exit("sink/filter/restore/save order wrong")
print("real-focus dual-path negative: filtered while editor unfocused, restored, saved unchanged")
PY

# M91: Escape is independently exercised on the real dual-path input seam.
# #2054 AC-C4 makes it two-step on the live path: the first Escape clears
# the typed query (the `q= ` filter marker), the second dismisses.
vgate_run 14 -- \
    --screen '$RUN_DIR/screen-14' --via-virtio \
    --script '$RUN_DIR/script-m87.txt' \
    --script2 '$RUN_DIR/script2-m87-edit.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '272,702,d;272,702,u' \
    --pointer-virtio-after 'goedit: present' \
    --input-string 'calc' --input-string-after 'gotabwm: launcher open n=' \
    --input-chords 'escape,escape' \
    --input-chords-after 'gotabwm: launcher filter q=calc n=3' \
    --script-expect 'gotabwm: launcher restore id=' --script-expect-tail 4 --timeout 120
vgate_assert 14 serial-contains 'gotabwm: launcher filter q= n='
vgate_assert 14 serial-contains 'gotabwm: launcher restore id='
vgate_assert 14 serial-contains 'gotabwm: launcher dismiss'
vgate_assert 14 share-equals EDIT/M87.TXT $'seed-line\n'
vgate_assert 14 serial-absent 'goedit: dirty'
vgate_assert 14 serial-absent 'gotabwm: launcher exec '
vgate_assert 14 serial-absent 'dui: term sel '
vgate_assert 14 serial-absent '[EXC] parking:'
vgate_assert 14 serial-absent 'exited status=139'
vgate_assert 14 python <<'PY'
import os, pathlib, re
s = pathlib.Path(os.environ["VG_SER"]).read_text(errors="replace")
edit = re.search(r"goedit: open id=(\d+)", s)
sink = re.search(r"gotabwm: launcher focus sink=(\d+)", s)
restore = re.search(r"gotabwm: launcher restore id=(\d+)", s)
assert edit and sink and restore and edit[1] == restore[1] and sink[1] != edit[1]
assert sink.start() < s.index("gotabwm: launcher filter q=calc n=3") < restore.start()
assert restore.start() < s.index("gotabwm: launcher dismiss")
print("Escape restored the former live editor after filtering, without app input")
PY

# NOTE is deliberately unstaged in this spec. Both it and the non-app
# fallback seat must remain visible and refuse clicks; padding is not a row.
vgate_file script-m91-unavailable.txt <<'EOF'
dui
echo rx-m91-unavailable-ok
EOF
vgate_run 15 -- \
    --screen '$RUN_DIR/screen-15' --via-virtio --cvc-snap \
    --snapshot-after 'gotabwm: launcher presented' \
    --snapshot-out '$RUN_DIR/menu-15' \
    --script '$RUN_DIR/script-m87.txt' \
    --script2 '$RUN_DIR/script2-m87-edit.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '272,702,d;272,702,u;2,150,d;2,150,u;20,175,d;20,175,u;20,460,d;20,460,u;800,650,d;800,650,u' \
    --pointer-virtio-after 'goedit: present' \
    --script3 '$RUN_DIR/script-m91-unavailable.txt' \
    --script3-after 'gotabwm: launcher restore id=' \
    --script-expect 'rx-m91-unavailable-ok' --timeout 150
vgate_assert 15 serial-absent 'gotabwm: launcher exec '
vgate_assert 15 serial-absent 'goedit: dirty'
vgate_assert 15 share-equals EDIT/M87.TXT $'seed-line\n'
vgate_assert 15 serial-absent 'dui: term sel '
vgate_assert 15 serial-absent 'gotabwm: reorder '
vgate_assert 15 serial-absent '[EXC] parking:'
vgate_assert 15 serial-absent 'exited status=139'
vgate_assert 15 snapshot 'menu-15-*.raw' <<'PY'
import pathlib, sys
exec((pathlib.Path(sys.argv[1]).parent / "menu-glyphs.py").read_text())
# Exact unavailable text, not just a gray rectangle: B in Binary not staged,
# under the dimmed NOTE label on strip row 1 (y=164; the reason sits at +13).
rows = [0x3f, 0x66, 0x66, 0x3e, 0x66, 0x66, 0x3f, 0]
x, y = 14, 177
def px(dx, dy):
    p = ((y + dy) * W + x + dx) * 4
    return raw[p:p+3]
bg, ink = px(7, 7), px(0, 0)
assert min(abs(a-b) for a, b in zip(ink, bg)) >= 32, "unavailable reason unreadable"
for dy, bits in enumerate(rows):
    for dx in range(8):
        assert px(dx, dy) == (ink if bits & (1 << dx) else bg), "unavailable glyph mismatch"
print("missing NOTE binary has readable unavailable reason pixels")
PY

# ---------------------------------------------------------------------------
# Run 16 (M121b / #2565): the tab chords — move-left/right on
# ctrl+shift+pageup/pagedown, pin on ctrl+shift+n, close on ctrl+shift+w.
#
# Same three-client boot as run 07: the last-declared client owns rail
# cell 2 on arrival, so the move pair is a real two-step (2->1 then 1->2),
# pin jumps the focused cell to the front, and ctrl+shift+w closes it --
# pin is a partition, not a lock. Every chord lands inside the same
# hidChordHold window run 07's pair does. Reopen and duplicate keep their
# own boots (runs 04/05): cv-input paces one batch at 0.25 s/stroke and a
# same-batch second re-exec chord lands before the first clone declares
# (the run-04 transport note). The chord SPELLINGS are the card's picks
# made against the registry, not its first proposals: ctrl+shift+p is
# M121a's palette and plain ctrl+w is GOSH.ELF's kill-word (its app row
# calls it "the chord the seat must never bind"), so close rides
# ctrl+shift+w — free at every scope.
vgate_run 16 -- \
    --screen '$RUN_DIR/screen-16' \
    --via-virtio \
    --script '$RUN_DIR/script-m79f.txt' \
    --script2 '$RUN_DIR/script2-m79f.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-pageup,ctrl-shift-pagedown,ctrl-shift-n,ctrl-shift-w' \
    --input-chords-after 'gotabwm: rail n=3' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-ok' --timeout 420

vgate_assert 16 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 16 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 16 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 16 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 16 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 16 serial-contains 'gotabwm: registered'
vgate_assert 16 serial-contains 'gotabwm: rail n=3'
# M121b: the move pair emits the shared reorder marker, pin the pin marker,
# close the shared host/tab close pair.
vgate_assert 16 serial-contains 'gotabwm: reorder '
vgate_assert 16 serial-contains 'gotabwm: pin id='
vgate_assert 16 serial-contains 'gotabwm: host close id='
vgate_assert 16 serial-contains 'gotabwm: tab close id='
vgate_assert 16 serial-contains 'gotabwm: rail n=2'
vgate_assert 16 serial-contains 'gotabwm: close'
vgate_assert 16 serial-contains 'gotabwm OK'
vgate_assert 16 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 16 serial-contains 'rx-gotabwm-hid-ok'
vgate_assert 16 serial-absent '[EXC] parking:'
vgate_assert 16 serial-absent 'exited status=139'
vgate_assert 16 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_after(prefix, start=0):
    for i in range(start, len(ser)):
        if ser[i].startswith(prefix):
            return i
    sys.exit("missing %s after %d" % (prefix, start))

def first_match_after(rx, start):
    for i in range(start, len(ser)):
        m = rx.match(ser[i])
        if m:
            return i, m
    sys.exit("missing /%s/ after %d" % (rx.pattern, start))

rail_re = re.compile(r"^gotabwm: rail n=3 focus=(\d+)$")
order3_re = re.compile(
    r"^gotabwm: order ids=(\d+),(\d+),(\d+) pin=(\d),(\d),(\d) focus=(\d+)$")
reorder_re = re.compile(r"^gotabwm: reorder (\d+)->(\d+)$")

rail_i, rail_m = first_match_after(rail_re, 0)
focus_id = rail_m.group(1)
# No order line exists before the first chord (vf rm SESSION.TABS means no
# restore dump), so the focused cell index is derived from the FIRST reorder
# marker — the chord's own `reorder from->to` — not assumed to be 2.
left_i, left_m = first_match_after(reorder_re, rail_i)
i, j = int(left_m.group(1)), int(left_m.group(2))
if j != i - 1 or i < 1:
    sys.exit("move-left must be i->i-1 with i>0, got %s" % left_m.group(0))
right_i, right_m = first_match_after(reorder_re, left_i + 1)
if (right_m.group(1), right_m.group(2)) != (str(i - 1), str(i)):
    sys.exit("move-right must be %d->%d, got %s" % (i - 1, i, right_m.group(0)))
# Focus followed the moved tab back to cell i.
back_i, back_m = first_match_after(order3_re, right_i)
if back_m.group(7) != focus_id or list(back_m.group(1, 2, 3)).index(focus_id) != i:
    sys.exit("after the move pair focus/order lost %s: %s" % (focus_id, back_m.group(0)))
# Pin: the focused cell jumps to the front with its pin bit set.
pin_i = first_after("gotabwm: pin id=" + focus_id, back_i)
pin_o_i, pin_o = first_match_after(order3_re, pin_i)
if pin_o.group(1) != focus_id or pin_o.group(4) != "1":
    sys.exit("pin did not front cell %s with its bit: %s" % (focus_id, pin_o.group(0)))
# Close: the pinned tab still closes (pin is a partition, not a lock), the
# shared close pair names it, and the rail drops to n=2.
host_i = first_after("gotabwm: host close id=" + focus_id, pin_i)
close_i = first_after("gotabwm: tab close id=" + focus_id, host_i)
rail2_i = first_after("gotabwm: rail n=2", close_i)
if not (rail_i < left_i < right_i < pin_i < close_i < rail2_i):
    sys.exit("chord marker chain out of order: rail@%d left@%d right@%d pin@%d close@%d n2@%d" % (
        rail_i, left_i, right_i, pin_i, close_i, rail2_i))
print("M121b: cell %d move %s->%s then %s->%s, pin fronted %s, close dropped to n=2" % (
    i, left_m.group(1), left_m.group(2), right_m.group(1), right_m.group(2), focus_id))
PY

# ---------------------------------------------------------------------------
# Runs 17–19 (M121e / #2568): the seat-owned ctrl+z undo chord.
#
# The seat row owns the chord's dispatch: a focused tab answers through its
# own app-scope binding — the seat routes, the KEY_DOWN (or the tty byte for
# a bound front-end) still reaches the app — and the strip-focused press is
# the seat's own undo, the reopen LIFO. GOSH/child-tty keeps the bare
# keystroke's meaning: the seat never swallows it.
#
# One boot per surface, never a focus switch inside a chord batch: the
# seat's WM_KEY mirror lags the app's own KEY_DOWN delivery (measured
# 2026-10-19 on the two-app variant: the alt-tab's mirror processed ~44k
# serial lines after the batch's tail strokes had all delivered to the
# still-focused first app — the trailing d,y,ctrl-z undid text in GOEDIT
# instead of touching GOFILES). The route marker is also emitted at
# seat-processing time, so it can print AFTER the app's own revert marker:
# the asserts pin the route's id, never its relative order.
#
# Run 17 (GOEDIT leg): run 01's pair boot. A rail click focuses GOEDIT
# (cell 0), XYZ types one merged run, ctrl-z pops it on the buffer's own
# op ring (the ActionUndo dispatch on the app's own KEY_DOWN), and the
# follow-up save must write the seed bytes exactly.
vgate_file script2-m121e.txt <<'EOF'
dui focus 0
exec GOFILES.ELF /host/FMUNDO
EOF

vgate_run 17 -- \
    --screen '$RUN_DIR/screen-17' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '320,10,c' \
    --pointer-virtio-after 'gotabwm: rail n=2' \
    --input-string 'XYZ' \
    --input-string-after 'gotabwm: rail-click id=' \
    --input-chords 'ctrl-z,ctrl-s' \
    --input-chords-after 'goedit: dirty' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-ok' --timeout 300

vgate_assert 17 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 17 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 17 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 17 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 17 serial-contains 'gotabwm: registered'
vgate_assert 17 serial-contains 'gotabwm: rail n=2'
vgate_assert 17 serial-contains 'gotabwm: rail-click id='
vgate_assert 17 serial-contains 'goedit: present'
vgate_assert 17 serial-contains 'gotabwm: key'
vgate_assert 17 serial-contains 'goedit: dirty'
# M121e: the chord routed (undo id= names GOEDIT's window) and the buffer's
# own op ring reverted the typed run — then the save writes the seed's 10
# bytes exactly. The route marker is seat-processed, so its serial position
# against the app's own markers is not pinned.
vgate_assert 17 serial-contains 'gotabwm: undo id='
vgate_assert 17 serial-contains 'goedit: undo n=0'
vgate_assert 17 serial-contains 'goedit: saved /host/EDIT/SEED.TXT n=10'
vgate_assert 17 serial-contains 'gotabwm OK'
vgate_assert 17 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 17 serial-contains 'rx-gotabwm-hid-ok'
vgate_assert 17 serial-absent 'goterm: line '
vgate_assert 17 serial-absent 'goedit: undo none'
vgate_assert 17 serial-absent '[EXC] parking:'
vgate_assert 17 serial-absent 'exited status=139'
vgate_assert 17 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_after(prefix, start=0):
    for i in range(start, len(ser)):
        if ser[i].startswith(prefix):
            return i
    sys.exit("missing %s after %d" % (prefix, start))

def first_match_after(rx, start):
    for i in range(start, len(ser)):
        m = rx.match(ser[i])
        if m:
            return i, m
    sys.exit("missing /%s/ after %d" % (rx.pattern, start))

# The route names GOEDIT's own window — the seat dispatches to the focused
# tab, and the app's own markers tell the revert story: the typed run
# merged to one op, the undo ring emptied (n=0), and the saved bytes are
# the seed exactly (a partial revert would save n>10).
open_i, open_m = first_match_after(re.compile(r"^goedit: open id=(\d+)"), 0)
route_i, route_m = first_match_after(
    re.compile(r"^gotabwm: undo id=(\d+)"), open_i)
if route_m.group(1) != open_m.group(1):
    sys.exit("undo routed to id=%s, want the focused editor %s" % (
        route_m.group(1), open_m.group(1)))
dirty_i = first_after("goedit: dirty")
undo_i = first_after("goedit: undo n=0", dirty_i)
saved_i = first_after("goedit: saved /host/EDIT/SEED.TXT n=10", undo_i)
if not (dirty_i < undo_i < saved_i):
    sys.exit("GOEDIT leg out of order: dirty@%d undo@%d saved@%d" % (
        dirty_i, undo_i, saved_i))
print("M121e GOEDIT leg: route id=%s@%d, undo@%d, saved-seed@%d" % (
    route_m.group(1), route_i, undo_i, saved_i))
PY

# Run 18 (M121e): the strip-focused press is the seat's own undo — the
# reopen LIFO. Run 04's exact boot shape (single GOCALC the demo
# choreography auto-closes), but the chord is ctrl-z: the strip owns undo
# with nothing focused, so the seat's answer is applyReopen — same LIFO,
# different chord.
vgate_run 18 -- \
    --screen '$RUN_DIR/screen-18' \
    --via-virtio \
    --script '$RUN_DIR/script-bt1.txt' \
    --script2 '$RUN_DIR/script2-bt1.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-z' \
    --input-chords-after 'gotabwm: tab close id=' \
    --script3 '$RUN_DIR/script3-bt1.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-bt1-ok' --timeout 300

vgate_assert 18 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 18 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 18 serial-contains 'gotabwm: registered'
vgate_assert 18 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 18 serial-contains 'gotabwm: tab open id='
vgate_assert 18 serial-contains 'gotabwm: tab close id='
# M121e: the strip-focused chord names the seat surface, then the LIFO
# supplies the tab — run 04's reopen outcome through the undo chord.
vgate_assert 18 serial-contains 'gotabwm: undo seat'
vgate_assert 18 serial-contains 'gotabwm: reopen GOCALC.ELF'
vgate_assert 18 serial-absent 'gotabwm: reopen missing '
vgate_assert 18 serial-contains 'gotabwm: close'
vgate_assert 18 serial-contains 'gotabwm OK'
vgate_assert 18 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 18 serial-contains 'rx-gotabwm-bt1-ok'
vgate_assert 18 serial-absent '[EXC] parking:'
vgate_assert 18 serial-absent 'exited status=139'
vgate_assert 18 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_after(prefix, start=0):
    for i in range(start, len(ser)):
        if ser[i].startswith(prefix):
            return i
    sys.exit("missing %s after %d" % (prefix, start))

close_i = first_after("gotabwm: tab close id=")
seat_i = first_after("gotabwm: undo seat", close_i)
reopen_i = first_after("gotabwm: reopen GOCALC.ELF", seat_i)
opens = [i for i, l in enumerate(ser) if l.startswith("gotabwm: tab open id=")]
if len([i for i in opens if i > reopen_i]) < 1:
    sys.exit("want a tab open after the undo reopen (reopen@%d opens=%s)" % (
        reopen_i, opens))
if not (close_i < seat_i < reopen_i):
    sys.exit("strip leg out of order: close@%d seat@%d reopen@%d" % (
        close_i, seat_i, reopen_i))
print("M121e strip leg: close@%d undo-seat@%d reopen@%d, %d tab opens" % (
    close_i, seat_i, reopen_i, len(opens)))
PY

# Run 19 (M121e): the GOFILES leg — the chord's bound-tty spelling. One
# hosted GOFILES on a one-file share: 'd,y' trashes NOTE.TXT, then ctrl-z
# reaches the tab as the 0x1a control byte (kernel/src/input.zig's
# ctrl+letter path — a bound front-end never sees a window KEY_DOWN) and
# lands on the model's own restore path, the `u` key's twin. The seat
# prints its route marker; go-fileman run 04 owns the `u` key's own
# delete/restore round-trip, so this leg only has to prove the chord took
# the same road.
vgate_file fmundo.expected <<'EOF'
m121e trash-restore
EOF

vgate_run 19 -- \
    --screen '$RUN_DIR/screen-19' \
    --via-virtio \
    --script '$RUN_DIR/script-bt1.txt' \
    --script2 '$RUN_DIR/script2-m121e.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'd,y,ctrl-z' \
    --input-chords-after 'gofiles: ready' \
    --script3 '$RUN_DIR/script3-bt1.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-bt1-ok' --timeout 300

vgate_assert 19 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 19 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 19 serial-contains 'gotabwm: registered'
vgate_assert 19 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 19 serial-contains 'gofiles: ready'
vgate_assert 19 serial-contains 'gofiles: deleted NOTE.TXT trash='
# M121e: the route marker names the focused tty-bound tab; the app's own
# marker names the revert. Serial order between them is not pinned (the
# seat's mirror is processed after delivery — see the run-17 note).
vgate_assert 19 serial-contains 'gotabwm: undo id='
vgate_assert 19 serial-contains 'gofiles: restored NOTE.TXT trash='
vgate_assert 19 share-equals FMUNDO/NOTE.TXT fmundo.expected
vgate_assert 19 share-contains RECENT/LOG.TXT '|delete|'
vgate_assert 19 share-contains RECENT/LOG.TXT '|restore|'
vgate_assert 19 serial-absent 'gofiles: delete refused NOTE.TXT rc='
vgate_assert 19 serial-absent 'gofiles: restore refused rc='
vgate_assert 19 serial-contains 'rx-gotabwm-bt1-ok'
vgate_assert 19 serial-absent '[EXC] parking:'
vgate_assert 19 serial-absent 'exited status=139'
vgate_assert 19 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_after(prefix, start=0):
    for i in range(start, len(ser)):
        if ser[i].startswith(prefix):
            return i
    sys.exit("missing %s after %d" % (prefix, start))

def first_match_after(rx, start):
    for i in range(start, len(ser)):
        m = rx.match(ser[i])
        if m:
            return i, m
    sys.exit("missing /%s/ after %d" % (rx.pattern, start))

open_i, open_m = first_match_after(re.compile(r"^gofiles: open id=(\d+)"), 0)
route_i, route_m = first_match_after(
    re.compile(r"^gotabwm: undo id=(\d+)"), open_i)
if route_m.group(1) != open_m.group(1):
    sys.exit("undo routed to id=%s, want the focused files tab %s" % (
        route_m.group(1), open_m.group(1)))
del_i = first_after("gofiles: deleted NOTE.TXT trash=")
restore_i = first_after("gofiles: restored NOTE.TXT trash=", del_i)
if not (del_i < restore_i):
    sys.exit("GOFILES leg out of order: del@%d restore@%d" % (del_i, restore_i))
print("M121e GOFILES leg: route id=%s@%d, deleted@%d, restored@%d" % (
    route_m.group(1), route_i, del_i, restore_i))
PY

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Run 20 (M190a / #3236): the clipboard-history paste menu. `clip alpha`
# seeds the older clip before the apps declare; GOFILES 'c' yanks NOTE.TXT
# — the M124c clip-sys publish lands a text/uri-list clip as the newer —
# the menu summons on ctrl-shift-i, down picks the OLDER clip, and Enter
# pastes through the existing deliver path: the typed write lands on the
# kernel buffer and the focused tab's own ctrl-v pulls it. `clip` readback
# proves the buffer holds the pick, `goedit: paste n=5` proves the app
# received it. Both copies are marker-ordered ahead of the chord batch —
# an in-batch app copy races the summon (the seat cannot observe a write
# the app has not completed yet), so the second distinct string is the
# monitor's own `clip` write rather than a GOEDIT ctrl-c.

vgate_file script2-m190a.txt <<'SCRIPT'
dui focus 0
exec -u0 GOEDIT.ELF /host/EDIT/SEED.TXT &
fg
exec -u0 GOFILES.ELF /host/FMUNDO
clip alpha
SCRIPT

vgate_file script3-m190a.txt <<'SCRIPT'
clip
wm
dui
echo rx-gotabwm-hid-ok
SCRIPT

vgate_run 20 -- \
    --screen '$RUN_DIR/screen-20' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-m190a.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-string 'c' \
    --input-string-after 'gofiles: ready' \
    --pointer-virtio '320,10,c' \
    --pointer-virtio-after 'gofiles: clip-sys ' \
    --input-chords 'ctrl-shift-i,down,return' \
    --input-chords-after 'gotabwm: rail-click id=' \
    --script3 '$RUN_DIR/script3-m190a.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-ok' --timeout 300

vgate_assert 20 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 20 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 20 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 20 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 20 serial-contains 'gotabwm: registered'
vgate_assert 20 serial-contains 'gofiles: ready'
# The two copies, typed honestly: the seeded text first (the older clip),
# the file yank's URI list second — the ring records each in copy order.
vgate_assert 20 serial-contains 'clip: stored 5 bytes'
vgate_assert 20 serial-contains 'gofiles: clip-sys n='
vgate_assert 20 serial-contains 'gotabwm: cliphist push mime=text/plain len=5 '
vgate_assert 20 serial-contains 'gotabwm: cliphist push mime=text/uri-list len=28 '
# The menu: two rows, down moves to the older clip, Enter delivers it.
vgate_assert 20 serial-contains 'gotabwm: clipmenu open n=2'
vgate_assert 20 serial-contains 'gotabwm: clipmenu pick i=1 mime=text/plain '
vgate_assert 20 serial-contains 'gotabwm: clipmenu dismiss'
vgate_assert 20 serial-contains 'gotabwm: clipmenu paste id='
vgate_assert 20 serial-contains 'goedit: paste n=5'
vgate_assert 20 serial-contains 'clip: alpha'
vgate_assert 20 serial-contains 'gotabwm OK'
vgate_assert 20 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 20 serial-contains 'rx-gotabwm-hid-ok'
vgate_assert 20 serial-absent 'gotabwm: clipmenu empty'
vgate_assert 20 serial-absent 'gotabwm: clipmenu paste refuse'
vgate_assert 20 serial-absent '[EXC] parking:'
vgate_assert 20 serial-absent 'exited status=139'
vgate_assert 20 python <<'PYEOF'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_after(prefix, start=0):
    for i in range(start, len(ser)):
        if ser[i].startswith(prefix):
            return i
    sys.exit("missing %s after %d" % (prefix, start))

def first_match_after(rx, start):
    for i in range(start, len(ser)):
        m = rx.match(ser[i])
        if m:
            return i, m
    sys.exit("missing /%s/ after %d" % (rx.pattern, start))

# The ring pushes in copy order — the seeded alpha first (the older
# clip), the file URI second — then the menu lists, picks index 1 (the
# older), and the focused editor's own paste lands it.
txt_i = first_after("gotabwm: cliphist push mime=text/plain len=5 ")
uri_i = first_after("gotabwm: cliphist push mime=text/uri-list len=28 ", txt_i)
open_i = first_after("gotabwm: clipmenu open n=2", uri_i)
pick_i = first_after("gotabwm: clipmenu pick i=1 ", open_i)
paste_i, paste_m = first_match_after(
    re.compile(r"^gotabwm: clipmenu paste id=(\d+) mime=text/plain len=5"), pick_i)
app_i, app_m = first_match_after(
    re.compile(r"^goedit: paste n=(\d+)"), paste_i)
open_m = re.match(r"^goedit: open id=(\d+)", ser[first_after("goedit: open id=")])
if paste_m.group(1) != open_m.group(1):
    sys.exit("paste targeted id=%s, want the focused editor %s" % (
        paste_m.group(1), open_m.group(1)))
if app_m.group(1) != "5":
    sys.exit("app pasted n=%s, want the older clip's 5 bytes" % app_m.group(1))
print("M190a leg: text push@%d uri push@%d menu@%d pick i=1@%d paste id=%s@%d app n=5@%d" % (
    txt_i, uri_i, open_i, pick_i, paste_m.group(1), paste_i, app_i))
PYEOF

# ---------------------------------------------------------------------------
# Run 21 (M191b / #3243): launcher verbs + filename hits. Seat-only; the
# filename hit is a real second result kind under a named bound. 'verb'
# names no app — the /host/LV/VERB.TXT hit is row 0 — so Tab arms the
# reveal verb and Enter execs GOFILES at the containing folder, whose
# one-file listing lands on VERB.TXT. A second summon types a query with
# no name match anywhere: the M165f hand-off row is the only offer left,
# and Enter on it execs `GOFILES.ELF --search <q>` — the content-intent
# answer stays the hand-off, never an inline snippet. Seat + two GOFILES
# clients is the #1449 wall the seat-only legs stay inside.
vgate_file script3-m191b.txt <<'SCRIPT'
wm
dui
echo rx-gotabwm-verbs-ok
SCRIPT

vgate_run 21 -- \
    --screen '$RUN_DIR/screen-21' \
    --via-virtio \
    --script '$RUN_DIR/script-bt1.txt' \
    --script2 '$RUN_DIR/script2-launch.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-space,v,e,r,b,tab,return' \
    --input-chords-after 'gotabwm: present' \
    --input-chords2 'ctrl-space,z,z,z,q,q,return' \
    --input-chords2-after 'gofiles: ready' \
    --script3 '$RUN_DIR/script3-m191b.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-verbs-ok' --timeout 300

vgate_assert 21 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 21 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 21 serial-contains 'gotabwm: registered'
vgate_assert 21 serial-contains 'gotabwm: launcher files q=verb n=1'
vgate_assert 21 serial-contains 'gotabwm: launcher filter q=verb n=2'
vgate_assert 21 serial-contains 'gotabwm: launcher verb reveal'
vgate_assert 21 serial-contains 'gotabwm: launcher exec GOFILES.ELF argv=/host/LV'
vgate_assert 21 serial-contains 'gofiles: list /host/LV n=1'
vgate_assert 21 serial-contains 'gofiles: entry VERB.TXT file'
# A name match nothing makes still offers the hand-off row: the lone
# filtered row on 'zzzqq' is the M165f search hand-off, and Enter runs it.
vgate_assert 21 serial-contains 'gotabwm: launcher files q=zzzqq n=0'
vgate_assert 21 serial-contains 'gotabwm: launcher filter q=zzzqq n=1'
vgate_assert 21 serial-contains 'gotabwm: launcher search q=zzzqq'
vgate_assert 21 serial-contains 'gofiles: search arg q=zzzqq'
vgate_assert 21 serial-exact 'exec: loaded GOFILES.ELF' 2
vgate_assert 21 serial-contains 'gotabwm OK'
vgate_assert 21 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 21 serial-contains 'rx-gotabwm-verbs-ok'
vgate_assert 21 serial-absent 'gotabwm: launcher missing '
vgate_assert 21 serial-absent '[EXC] parking:'
vgate_assert 21 serial-absent 'exited status=139'
vgate_assert 21 python <<'PYEOF'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_after(prefix, start=0):
    for i in range(start, len(ser)):
        if ser[i].startswith(prefix):
            return i
    sys.exit("missing %s after %d" % (prefix, start))

files_i = first_after("gotabwm: launcher files q=verb n=1")
verb_i = first_after("gotabwm: launcher verb reveal", files_i)
exec_i = first_after("gotabwm: launcher exec GOFILES.ELF argv=/host/LV", verb_i)
list_i = first_after("gofiles: list /host/LV n=1", exec_i)
entry_i = first_after("gofiles: entry VERB.TXT file", list_i)
search_i = first_after("gotabwm: launcher search q=zzzqq", entry_i)
arg_i = first_after("gofiles: search arg q=zzzqq", search_i)
if not (files_i < verb_i < exec_i < list_i < entry_i < search_i < arg_i):
    sys.exit("verb leg out of order: files@%d verb@%d exec@%d list@%d entry@%d search@%d arg@%d" % (
        files_i, verb_i, exec_i, list_i, entry_i, search_i, arg_i))
print("M191b leg: hit@%d verb@%d exec@%d list@%d hand-off@%d arg@%d" % (
    files_i, verb_i, exec_i, list_i, search_i, arg_i))
PYEOF

# --- run 22 (M190c / #3238): the rail-depth leg -------------------------
# Seat + GOEDIT + GOCLOCK (three Go runtimes, inside the #1449 wall at
# GOMAXPROCS=1). GOEDIT declares first (cell 0), GOCLOCK second (cell 1,
# focused). Chords arm a 3s timer; its expiry posts a kind-12 toast, so
# the badge counts it on GOCLOCK's cell (`rail badge id=<clock> n=1`).
# The pointer script then: left-clicks cell 0 (seat focus moves to
# GOEDIT), left-clicks cell 1 (GOCLOCK takes focus -> `rail badge n=0`),
# right-clicks cell 1 (the button-2 menu opens, `rail menu open id=`),
# and left-clicks the Quit row (`rail menu pick quit` -> the close-x's
# closeTabByID seam -> `host close`/`tab close` and the window is gone).
# Menu geometry for n=2: cell 1 anchors the panel at x=640, Quit is row
# 3 of the 4x20px list at y=RailHeight+2 => the click lands (700,97).
vgate_file script2-m190c.txt <<'SCRIPT'
exec GOEDIT.ELF &
fg
exec GOCLOCK.ELF
SCRIPT

vgate_file script3-m190c.txt <<'SCRIPT'
wm
dui
echo rx-gotabwm-hid-menu-ok
SCRIPT

vgate_run 22 -- \
    --screen '$RUN_DIR/screen-22' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-m190c.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'right,right,e,3,return' \
    --input-chords-after 'goclock: painted epoch=' \
    --pointer-virtio '320,10,c;960,10,c;960,10,rc;700,97,c' \
    --pointer-virtio-after 'goclock: timer armed 3' \
    --script3 '$RUN_DIR/script3-m190c.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-hid-menu-ok' --timeout 300

vgate_assert 22 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 22 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 22 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 22 serial-contains 'gotabwm: rail n=2'
vgate_assert 22 serial-contains 'goclock: timer armed 3'
vgate_assert 22 serial-contains 'goclock: fired timer'
vgate_assert 22 serial-contains 'gotabwm: notify id='
vgate_assert 22 serial-contains 'timer done'
vgate_assert 22 serial-contains 'gotabwm: rail badge id='
vgate_assert 22 serial-contains 'gotabwm: rail menu open id='
vgate_assert 22 serial-contains 'gotabwm: rail menu pick quit id='
vgate_assert 22 serial-contains 'gotabwm: close'
vgate_assert 22 serial-contains 'gotabwm OK'
vgate_assert 22 serial-contains 'rx-gotabwm-hid-menu-ok'
vgate_assert 22 serial-absent '[EXC] parking:'
vgate_assert 22 serial-absent 'exited status=139'
vgate_assert 22 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()

def first_match(rx, start=0):
    for i in range(start, len(ser)):
        m = rx.match(ser[i])
        if m:
            return i, m
    sys.exit("missing /%s/ after %d" % (rx.pattern, start))

edit_re = re.compile(r"^goedit: open id=(\d+)$")
clock_re = re.compile(r"^goclock: open id=(\d+)$")
badge_re = re.compile(r"^gotabwm: rail badge id=(\d+) n=(\d+)$")
click_re = re.compile(r"^gotabwm: rail-click id=(\d+)$")
menu_re = re.compile(r"^gotabwm: rail menu open id=(\d+)$")
pick_re = re.compile(r"^gotabwm: rail menu pick quit id=(\d+)$")
close_re = re.compile(r"^gotabwm: tab close id=(\d+)$")

_, edit_m = first_match(edit_re)
_, clock_m = first_match(clock_re)
edit_id, clock_id = edit_m.group(1), clock_m.group(1)

# The toast lands as a badge on GOCLOCK's cell, then its focus click
# clears it, then the button-2 menu's Quit takes the window down.
queued_i, _ = first_match(re.compile(r"^gotabwm: notify id=" + clock_id + " "))
badge_i, badge_m = first_match(badge_re, queued_i)
if badge_m.group(1) != clock_id or badge_m.group(2) != "1":
    sys.exit("first badge transition = id=%s n=%s, want id=%s n=1" % (
        badge_m.group(1), badge_m.group(2), clock_id))
click_i, click_m = first_match(click_re, badge_i)
if click_m.group(1) != edit_id:
    sys.exit("first rail click after the badge hit id=%s want GOEDIT %s" % (
        click_m.group(1), edit_id))
click2_i, click2_m = first_match(click_re, click_i + 1)
if click2_m.group(1) != clock_id:
    sys.exit("second rail click id=%s want GOCLOCK %s" % (click2_m.group(1), clock_id))
clear_i, clear_m = first_match(badge_re, click2_i)
if clear_m.group(1) != clock_id or clear_m.group(2) != "0":
    sys.exit("badge clear = id=%s n=%s, want id=%s n=0" % (
        clear_m.group(1), clear_m.group(2), clock_id))
menu_i, menu_m = first_match(menu_re, clear_i)
if menu_m.group(1) != clock_id:
    sys.exit("menu opened on id=%s want GOCLOCK %s" % (menu_m.group(1), clock_id))
pick_i, pick_m = first_match(pick_re, menu_i)
if pick_m.group(1) != clock_id:
    sys.exit("quit pick id=%s want %s" % (pick_m.group(1), clock_id))
close_i, close_m = first_match(close_re, pick_i)
if close_m.group(1) != clock_id:
    sys.exit("closed id=%s want %s" % (close_m.group(1), clock_id))
# The strip drops to one live cell.
if not any(re.match(r"^gotabwm: rail n=1 ", l) for l in ser[close_i:]):
    sys.exit("no rail n=1 after the quit")
print("M190c leg: badge n=1@%d clear@%d menu@%d quit->close@%d" % (
    badge_i, clear_i, menu_i, close_i))
PY
