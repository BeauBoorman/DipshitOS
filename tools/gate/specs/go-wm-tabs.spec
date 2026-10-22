# go-wm-tabs.spec -- M62b–h + #1426 + M66b + M79d + M79g + M104e
# (issues #1400–#1406/#1426/#1444/#1707/#1718/#2272)
# class-B gate: GOTABWM tab strip, split, pin, session, LAYOUT.txt, then two
# shipping Go ELFs as tabs. Boot 01 hosts GOCALC.ELF + NOTE.ELF
# (Zig CALC.BIN is gone, M62h / #1406; Zig NOTEPAD.BIN is gone, M66c / #1485). Boot 03 hosts GOEDIT.ELF + GOTERM.ELF:
# both declared, focus switch, both alive, close one without killing the
# seat, LAYOUT.txt names both bins. scheduler.max_tasks=64 (M129b /
# #2611; was 16 under M65d). The GOMAXPROCS=1 path still fits
# (GOTABWM+GOEDIT+GOTERM = 9 Ms + kernel 3; idle stays max_tasks-1).
#
# TWENTY-FIVE vgate_runs share one seeded host share (`vgate_share seed`):
#   01  GOCALC+NOTE.ELF; pin-stay writes SESSION.TABS; last unsplit writes
#       LAYOUT.txt (closed before the serial line that names it).
#       M79g: the choreography's closes now persist too, so the file this
#       boot leaves is the ONE tab it ended with.
#   02  GOTABWM only. Restores the session; then drops SESSION.TABS.
#   03  GOEDIT+GOTERM, empty strip. Same two-tab choreography.
#   04  M71e (#1564): GOCALC+NOTE.ELF, ctrl-shift-f freezes the tab that the
#       choreography does NOT close first, so the frozen bit survives to
#       SESSION.TABS (it is the only record left when the strip empties).
#   05  M71e (#1564): seat only, empty strip, no click. The start surface is
#       asserted as PIXELS on a settled frame (capture keyed to an rx marker,
#       not to `gotabwm: present` - the host grab races the guest present).
#   06  M71e (#1564): seat only, empty strip. A click on the panel opens the
#       launcher the surface advertises (serial only; the launcher covers the
#       panel, so run 05 owns the pixel assertion).
#   07  M79c (#1706): GOCALC+NOTE.ELF. ctrl-shift-v splits (the cycle chord,
#       live mode's only split entry) inside the choreography's 32-tick HID
#       hold; a `--pointer-virtio` press-drag-release on the divider moves
#       the sash 640 -> 800 with the 6 px gutter; the run ends at its own rx
#       marker, so the choreography never fires and LAYOUT.txt keeps the
#       sash geometry.
#   08  M79e (#1708): GOFILES.ELF as the nav adopter. The app declares its
#       start path, descends one directory (a second declare), the user
#       presses ctrl-shift-[, the seat queues the older path and hands it
#       back on the app's nav-poll — the client marker `gofiles: nav back
#       to` is the proof the round trip closed over the real wire. This is
#       the first run where a HOSTED Go app drives the kinds 9/10 seam.
#   09  M79g (#1718): LIVE mode (the GOTABWM.DEMO trigger is removed first),
#       GOCALC+NOTE.ELF. One rail click focuses Calc, ctrl-shift-n pins it
#       (pin's chord since M121a, when ctrl-shift-p went to the palette),
#       ctrl-shift-f freezes it, and a rail DRAG moves it to the right — each
#       mutation writes SESSION.TABS as it happens, and the run ends at its
#       own rx marker with the seat still up.
#   10  M79g (#1718) + M120b (#2559): the second boot of that pair. No HID,
#       no scripted clients: the seat restores the file run 09 wrote and
#       re-execs the recorded bins — `session load n=2 mode=restore`,
#       `session reexec n=2`, `session live n=2` — keeping the ORDER, the
#       pin bit and the frozen badge the user actually left, on real window
#       ids < 0x100 (adopted rows, not placeholder accumulation).
#       M104e (#2272): the restored rail is also asserted as PIXELS — the
#       §2.3.6 Selection + 3px Accent marker on the focused cell, the
#       close glyph's zone, and the frozen badge.
#   11  M97g-F2 (#2080): NOTE.ELF as the bound victim, WMRPCPROBE.ELF as the
#       in-guest attacker. The probe binds its own window honestly, then
#       sprays forged SetTitle frames (bare and guessed-token) at every other
#       user window id plus an unproven challenge echo — zero may apply while
#       its own bound requests still land. M137a (#2771): the same probe
#       then sends a BOUND kind-29 agent_input — the session token is
#       real but the principal is not AGENTD, so the seat answers
#       agent_input_denied (R2).
#   12  M125a (#2586): GOTABAPP.ELF as the state client. ctrl-shift-s makes
#       the seat post its kind-20 ask; the app stages its blob at
#       /host/APPSTATE.<id> and the seat stores it — SESSION.TABS's
#       app_state trailer is asserted byte-for-byte on the share.
#   13  M125a (#2586): the second boot. The seat restores the file run 12
#       wrote, re-execs GOTABAPP.ELF, and the app's restore_state request
#       hands the blob back — `gotabapp: state restored len=30` is the
#       app's own byte-identity verdict.
#   14  M125b (#2587): GOEDIT.ELF as the state client — a real session:
#       goto line 2, a find that lands its match selected, a replace-typed
#       char, undo+redo, a mark-extended selection, then ctrl-s + the
#       snapshot chord. SESSION.TABS's app_state trailer carries the blob.
#   15  M125b (#2587): the second boot. The seat restores run 14's file,
#       re-execs GOEDIT.ELF (bare bin — no argv exists on a re-exec), and
#       `goedit: state restored` reports caret/selection/rings/histories
#       back; a post-restore ctrl-z PROVES the ring is live, not a parse.
#   16  M125d (#2589): WEB.ELF as the state client — browse a form page,
#       scroll, type into a text field, toggle a checkbox, move a select,
#       then the snapshot chord. SESSION.TABS's AS trailer carries the
#       app's v1 blob (target + scroll + zoom + field values).
#   17  M125d (#2589): the second boot. The seat restores run 16's file,
#       re-execs WEB.ELF (bare bin — the blob's url field is the only
#       carrier), and `web: state restored` reports url/scroll/zoom and
#       3/3 fields re-applied onto the refetched page.
#   18  M125g (#2592): the acceptance — ONE session carrying all three real
#       state clients (GOTERM + WEB + GOEDIT): the terminal gets cwd/env/
#       scrollback from the share's own startup contract (PROFILE.SH),
#       the editor gets typed text, the snapshot chord asks every bound
#       tab, and the run's end IS the hard kill — VMRunner exits with the
#       session live and nothing but the crash-safe SESSION.TABS publish
#       crosses onto the share.
#   19  M125g (#2592): the restart. A fresh boot decodes the file the kill
#       left behind, re-execs all three rows, and each app's restore marker
#       reports its own state back — cwd/env/scroll, url, caret/rings.
#   22  M137c (#2773): spaces. LIVE mode, GOCALC+NOTE on space "1";
#       ctrl-alt-pagedown CREATES space "2", the launcher lands GOEDIT on
#       it, the palette's move-to-space row carries a tab across,
#       ctrl-shift-e summons GOEMOJI (absent -> named refusal), and the
#       snapshot chord captures both spaces — the .tabs group field and
#       the SESSION.PANES v2 frame asserted on the share.
#   23  M137c (#2773): the restore. A fresh boot stages SNAPSHOT.RESTORE,
#       the bundle rehydrates the two-space session + sidecar, and a
#       switch chord round-trips the restored table — every space intact.
#   24  M151a (#2912): pane posture. LIVE mode, GOCALC+NOTE. The split
#       chord, then the palette's "Zoom pane" row: the LAYOUT dump shows
#       the focused leaf full-viewport and a `dui` registry dump (the
#       scanout probe) shows the kernel's real rect + the parked
#       sibling's visible=0 while zoomed. "Restore panes" then a rail
#       drag released over the other pane's client rect — `pane drop` —
#       and a close-x on the focused cell: `focus restore ... why=close`
#       names the MRU survivor. The run ends on the seat's own marker.
#   25  M151b (#2913): the visible space switcher. LIVE mode, GOCALC+NOTE
#       on space "1"; the chord creates spaces 2+3, GOEDIT lands on 3,
#       the palette's "Switch to space 3" row carries the desktop over,
#       and a `--pointer-virtio` click on pill "1" prints `space pick 1`
#       before `space switch 3->1`. A marker-keyed screen capture is the
#       scanout probe: three pills, the live one on the Accent plate.
#
# Seed wm=none and exec GOTABWM.ELF like go-wm-seat. No HID. No framebuffer
# golden. Do not overload go-wm-seat or go-wm-default. Boot 01 `reorder 0->1`
# is M62d auto-choreography; HID press/release Reorder() is go-wm-hid run 02.
#
# M66b (#1444): SESSION.TABS and LAYOUT.txt are written through the
# crash-safe replace-write (vi.WriteFileSafe: temp + fsync + rename, never
# an in-place truncate), and each boot decodes the seeded SETTINGS.TXT —
# `gotabwm: settings wm=none` is the seat's read of the schema-v2 file.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-goedit.sh    ->  .build/go/GOEDIT.ELF
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#   bash tools/go/build-goterm.sh    ->  .build/go/GOTERM.ELF
#   bash tools/go/build-files.sh     ->  .build/go/GOFILES.ELF   (run 08)
#   bash tools/go/build-tabapp.sh    ->  .build/go/GOTABAPP.ELF  (runs 12/13)
#   bash tools/go/build-web.sh       ->  .build/go/WEB.ELF       (runs 16/17)
#
# exec-order: assert-proven -- each run ends on a marker only its script
# prints (`rx-gotabwm-tabs-ok` / `rx-gotabwm-session-ok` / `rx-gotabwm-apps-ok`).
# Stage gates wait on guest output (`gotabwm: win focus`,
# `wm: unregistered, shim resumed`). Boot 03 uses GOMAXPROCS=1 so each Go
# runtime stays at 3 kernel tasks (primary + sysmon + helper).
# M66c (#1445 retarget, #1485 retirement): the client is NOTE.ELF, the Go
# successor to the Zig notepad, and the Zig binary itself is now GONE. The
# lifecycle vocabulary is shared by design (`note:` mirrors `notepad:`), so the
# assertions below moved by prefix alone. The coverage that app alone had moved
# to GOEDIT.ELF (find/goto, the unsaved-decline contract) or GOCOMP.ELF (its
# clipboard+timer composition); the theme-token boots were retired with it.
# M79d (#1707): NOTE follows its opened file with kind-11 set_title. Run 01
# requires the seat's post-mutation marker and SESSION.TABS carries notes.txt;
# run 02 restores that title while LAYOUT.txt still records bin=NOTE.ELF, so a
# visible rename cannot corrupt reopen identity.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF
# HOST PREREQUISITE: bash tools/go/build-web.sh wmrpcprobe WMRPCPROBE -> .build/go/WMRPCPROBE.ELF (run 11)

vgate_name go-wm-tabs "issues #1400–#1405/#1426 + #1564 + #1707 + #1718 + #2559: GOTABWM tabs, session, LAYOUT.txt, frozen badge, start surface, live titles, and a session file that records what the user did on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
exec NOTE.ELF
EOF

vgate_file script3.txt <<'EOF'
wm
dui
echo rx-gotabwm-tabs-ok
EOF

vgate_file script-02.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-02.txt <<'EOF'
wm
echo rx-gotabwm-session-ok
EOF

# Boot 03: two shipping Go ELFs (GOEDIT + GOTERM). max_tasks=64 (M129b / #2611; was 16 under M65d).
# GOMAXPROCS=1 still fits three Go runtimes (seat + two clients); it is the
# exec envp knob (#1226).
vgate_file script-03.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-03.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF
exec GOTERM.ELF
EOF

vgate_file script3-03.txt <<'EOF'
wm
dui
echo rx-gotabwm-apps-ok
EOF

# M79a (#1704): the seat's bounded demo choreography (auto-close, the
# reorder/pin/split chain, the run budget) is DEMO mode, opted in by the
# PRESENCE of /host/GOTABWM.DEMO. Every boot of this spec drives that
# choreography (this spec IS the choreography's driver), so the trigger is
# seeded like any other share fixture; a daily session never stages it and
# gets the live seat (go-wm-seat run 05 proves that path end to end).
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
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
src = os.path.join(".build", "go", "GOTERM.ELF")
if not os.path.exists(src):
    sys.exit("GOTERM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goterm.sh")
shutil.copy(src, os.path.join(share, "GOTERM.ELF"))
print("staged GOTERM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTERM.ELF")))
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
seed = os.path.join(ed, "SEED.TXT")
with open(seed, "wb") as f:
    f.write(b"seed-line\n")
print("seeded %s (%d bytes)" % (seed, os.path.getsize(seed)))
# Explicit opt-in, same as go-wm-seat: the compiled default is already the
# Go seat (M59). Seed wm=none so this boot proves the tab strip on an
# executed GOTABWM, not the autostart path.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("seeded SETTINGS.TXT (wm=none: shim-only boot, explicit seat opt-in)")
# Seed is a fresh RUN_DIR/share per gate, but a leftover SESSION.TABS on a
# reused share would make boot 01 loadSession set stripDone and skip the
# M62b–d choreography. Drop it so boot 01 starts empty.
stale = os.path.join(share, "SESSION.TABS")
if os.path.exists(stale):
    os.remove(stale)
    print("cleared stale SESSION.TABS")
PY

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "NOTE.ELF")
if not os.path.exists(src):
    sys.exit("NOTE.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-note.sh")
shutil.copy(src, os.path.join(share, "NOTE.ELF"))
print("staged NOTE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "NOTE.ELF")))
PY

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOFILES.ELF")
if not os.path.exists(src):
    sys.exit("GOFILES.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-files.sh")
shutil.copy(src, os.path.join(share, "GOFILES.ELF"))
# M79e (#1708): the nav fixture. GOFILES takes its start path from argv, so
# run 08 starts it at /host/NAV, and NAV holds EXACTLY ONE entry which is a
# directory. That makes the first Return deterministic: entry 0 is SUBDIR, so
# the app descends to /host/NAV/SUBDIR without the gate having to know how the
# share sorts. Two declared paths, which is the minimum a back-step needs.
nav = os.path.join(share, "NAV")
sub = os.path.join(nav, "SUBDIR")
os.makedirs(sub, exist_ok=True)
with open(os.path.join(sub, "INNER.TXT"), "w") as f:
    f.write("inner\n")
print("staged GOFILES.ELF (%d bytes) + %s/INNER.TXT" %
      (os.path.getsize(os.path.join(share, "GOFILES.ELF")), sub))
PY

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "WMRPCPROBE.ELF")
if not os.path.exists(src):
    sys.exit("WMRPCPROBE.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-web.sh wmrpcprobe WMRPCPROBE")
shutil.copy(src, os.path.join(share, "WMRPCPROBE.ELF"))
print("staged WMRPCPROBE.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "WMRPCPROBE.ELF")))
PY

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTABAPP.ELF")
if not os.path.exists(src):
    sys.exit("GOTABAPP.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-tabapp.sh")
shutil.copy(src, os.path.join(share, "GOTABAPP.ELF"))
print("staged GOTABAPP.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTABAPP.ELF")))
PY

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "WEB.ELF")
if not os.path.exists(src):
    sys.exit("WEB.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-web.sh")
shutil.copy(src, os.path.join(share, "WEB.ELF"))
# M125d (#2589): the state page. Taller than the 720 CSS px viewport so a
# pagedown leaves a real scroll offset, with a text input, a checkbox and
# a select — the three control shapes the v1 blob carries.
with open(os.path.join(share, "FORM.HTML"), "w") as f:
    f.write("<h1>state page</h1>"
            '<p style="height:900px">spacer</p>'
            '<form action="/host/FORM.HTML">'
            '<input type="text" name="q">'
            '<input type="checkbox" name="ck">'
            '<select name="pick">'
            "<option>alpha</option><option>beta</option>"
            "</select></form>\n")
print("staged WEB.ELF (%d bytes) + FORM.HTML" %
      os.path.getsize(os.path.join(share, "WEB.ELF")))
PY

vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
# M125g (#2592): the acceptance session's fixtures. EDIT/M125G.TXT is the
# editor's open target; PROFILE.SH is the shell startup contract GOTERM
# sources at every boot — `cd /M125G` + an env var + a proof line give the
# terminal real cwd/env/scrollback state without spending an input phase
# (the legs need the two scripted input slots elsewhere). The lines are
# silent (no `goterm: line` markers — nobody typed them) and the other
# GOTERM boot in this spec (run 03) asserts nothing they could trip.
os.makedirs(os.path.join(share, "M125G"), exist_ok=True)
with open(os.path.join(share, "PROFILE.SH"), "w") as f:
    f.write("cd /M125G\nset M125G_X=alive-7\necho M125G-PROOF\n")
with open(os.path.join(share, "EDIT", "M125G.TXT"), "wb") as f:
    f.write(b"m125g-session\n")
print("staged PROFILE.SH + EDIT/M125G.TXT (run 18/19 session fixtures)")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-tabs-ok' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
# M66b (#1444): the seat decoded the seeded schema-v2 SETTINGS.TXT (wm=none).
vgate_assert 01 serial-contains 'gotabwm: settings wm=none'
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'exec: loaded NOTE.ELF'
# M104e (#2272): the seat's one-shot font report — this share stages no
# FONTS.TXT, so it names the bitmap degrade the rail's chrome glyphs ride.
vgate_assert 01 serial-contains 'gotabwm: fonts '
# Two clients on the strip, rail painted, one focused.
vgate_assert 01 serial-count 'gotabwm: tab open id=' 2
vgate_assert 01 serial-contains 'gotabwm: tab focus id='
vgate_assert 01 serial-contains 'gotabwm: rail n=2 focus='
vgate_assert 01 serial-contains 'gocalc: declare accepted'
vgate_assert 01 serial-contains 'note: tab-aware (full-viewport)'
# M79d: NOTE reports the rename only after the seat acked kind 11; the seat
# prints its marker only after the strip mutation. Pin both sides of the RPC.
vgate_assert 01 serial-contains 'note: tab title notes.txt'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
if not re.search(r"^gotabwm: title id=\d+ notes\.txt$", ser, re.M):
    sys.exit("missing gotabwm: title id=<n> notes.txt after NOTE declaration")
print("NOTE renamed its tab through WM_RPC kind 11")
PY
# M62d: reorder two unpinned tabs; pin jumps to the left and stays there
# across a focus change. Order line names ids + pin bits (not LAYOUT.txt).
# There is no kernel pin object: the first dump is Pin() on the strip; the
# second is only printed after WmctlTaskbarClick actually took focus.
# This `reorder 0->1` is applySwapUnpinned (choreography), not M63d HID drag.
vgate_assert 01 serial-contains 'gotabwm: reorder 0->1'
vgate_assert 01 serial-contains 'gotabwm: pin id='
vgate_assert 01 serial-contains 'gotabwm: order ids='
vgate_assert 01 serial-contains 'pin=1,0'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
order_re = re.compile(
    r"^gotabwm: order ids=(\d+),(\d+) pin=(\d),(\d) focus=(\d+)$")
pinned = []
for line in ser.splitlines():
    m = order_re.match(line)
    if not m:
        continue
    if m.group(3) == "1" and m.group(4) == "0":
        pinned.append((m.group(1), m.group(2), m.group(5)))
if len(pinned) < 2:
    sys.exit("want >=2 order lines with pin=1,0 (pin then focus), got %d" %
             len(pinned))
if pinned[0][0] != pinned[1][0] or pinned[0][1] != pinned[1][1]:
    sys.exit("pin did not stay left across focus: %s then %s" % (
        pinned[0], pinned[1]))
if pinned[0][2] == pinned[1][2]:
    sys.exit("focus did not change between pin-left dumps: focus=%s" %
             pinned[0][2])
print("pin stayed left ids=%s,%s across focus %s -> %s" % (
    pinned[0][0], pinned[0][1], pinned[0][2], pinned[1][2]))
PY
# M62c: integer two-pane split. Dump lines (LAYOUT.txt shape) plus the
# applied pane (SET_WINDOW accepted; slot 19 WinQuery is owner-only so
# the seat cannot read a hosted client's rect). Unsplit restores 1280x720.
# Remainder-free on this scanout. Clients print resize relayout = WIN_RESIZE.
vgate_assert 01 serial-contains 'gotabwm: split v'
vgate_assert 01 serial-contains 'split=v'
vgate_assert 01 serial-contains 'x=640 y=0 w=640 h=720'
vgate_assert 01 serial-contains 'gotabwm: split h'
vgate_assert 01 serial-contains 'split=h'
vgate_assert 01 serial-contains 'y=360 w=1280 h=360'
vgate_assert 01 serial-count 'gotabwm: unsplit' 2
vgate_assert 01 serial-contains 'split=none'
vgate_assert 01 serial-contains 'x=0 y=0 w=1280 h=720'
vgate_assert 01 serial-contains 'gocalc: present'
vgate_assert 01 serial-contains 'note: resize relayout'
# Pair each layout dump with the applied pane line dumpTab prints next.
# Every pair must match within 1 px (integer-half remainder).
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lay_re = re.compile(
    r"^gotabwm: layout tab=(\d+) bin=\S+ x=(\d+) y=(\d+) w=(\d+) h=(\d+) ")
pane_re = re.compile(
    r"^gotabwm: pane id=(\d+) x=(\d+) y=(\d+) w=(\d+) h=(\d+)$")
n = 0
pending = None
for line in ser.splitlines():
    lm = lay_re.match(line)
    if lm:
        pending = lm
        continue
    pm = pane_re.match(line)
    if not pm:
        continue
    if pending is None:
        sys.exit("pane line with no preceding layout dump: " + line)
    if pending.group(1) != pm.group(1):
        sys.exit("layout tab=%s paired with pane id=%s" % (
            pending.group(1), pm.group(1)))
    for i, name in ((2, "x"), (3, "y"), (4, "w"), (5, "h")):
        a, b = int(pending.group(i)), int(pm.group(i))
        if abs(a - b) > 1:
            sys.exit("tab %s %s dump=%d applied=%d (tol 1)" % (
                pending.group(1), name, a, b))
    n += 1
    pending = None
if n < 8:
    sys.exit("only %d layout/pane pairs (want >= 8: V+unsplit+H+unsplit x2)" % n)
print("layout vs applied pane: %d pairs within 1 px" % n)
PY
# Close focused -> remaining focused -> last close leaves the strip empty
# while the seat is still in its composite loop (tabs empty before close).
vgate_assert 01 serial-count 'gotabwm: tab close id=' 2
vgate_assert 01 serial-contains 'gotabwm: rail n=1 focus='
vgate_assert 01 serial-contains 'gotabwm: tabs empty'
vgate_assert 01 serial-contains 'gocalc: close'
vgate_assert 01 serial-contains 'note: win_close'
vgate_assert 01 serial-contains 'gotabwm: host done'
vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-gotabwm-tabs-ok'
# M52: no zombie window, registry back to the four fixed layers.
vgate_assert 01 serial-contains 'dui: windows=4 focused='
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
# M62e: pin-stay wrote `.tabs` v2 while both tabs still existed.
# M79g (#1718): a close is a mutation too, so the file this boot leaves is
# the strip it ENDED with — one tab (the choreography closed Calc first,
# because pin-stay pinned it) — and closing the last tab still must not
# publish an empty session. The two-tab restore this used to prove moved to
# the user-driven boot pair 09/10 below, where the tab order is the user's.
vgate_assert 01 serial-contains 'gotabwm: session write n=2'
vgate_assert 01 serial-contains 'gotabwm: session write n=1'
vgate_assert 01 python <<'PY'
import os, sys
# Offsets match user/go/gotabwm/tabsv2.go: tabsV2HeaderBytes=6,
# tabsV2RecordBytes=69, tabsV2TitleMax=32. Record 0 title at 6, flags at
# 38, group at 39, bin at 51.
p = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
try:
    b = open(p, "rb").read()
except FileNotFoundError:
    sys.exit("SESSION.TABS missing on the share")
if len(b) < 6 + 69:
    sys.exit("SESSION.TABS too short: %d bytes" % len(b))
if b[0] != 2:
    sys.exit("version byte %d want 2" % b[0])
if b[2] != 1:
    sys.exit("count %d want 1 (the choreography closed the pinned tab)" % b[2])
if b[1] != 1:
    sys.exit("active+1 = %d want 1 (the one surviving tab)" % b[1])
title = b[6:38].split(b"\x00", 1)[0]
if title != b"notes.txt":
    sys.exit("title %r want notes.txt (M79d's live title)" % title)
if b[38] != 0:
    sys.exit("flags %#x want 0 (the pinned tab was the one closed)" % b[38])
bin0 = b[51:75].split(b"\x00", 1)[0]
if bin0 != b"NOTE.ELF":
    sys.exit("bin %r want NOTE.ELF (reopen identity survives the rename)" % bin0)
print("SESSION.TABS v2 n=1 notes.txt bin=NOTE.ELF: the strip the boot ended with")
PY
# M62f: LAYOUT.txt is closed before the serial line that names it. Last
# two-tab write is the unsplit full-viewport dump (closes do not rewrite).
vgate_assert 01 serial-contains 'gotabwm: layout file=/host/SELFTEST/LAYOUT.txt'
vgate_assert 01 share-contains SELFTEST/LAYOUT.txt 'split=none'
vgate_assert 01 python <<'PY'
import os, re, sys
p = os.path.join(os.environ["VG_SHARE"], "SELFTEST/LAYOUT.txt")
try:
    raw = open(p, "rb").read()
except FileNotFoundError:
    sys.exit("SELFTEST/LAYOUT.txt missing on the share")
if b"\r" in raw:
    sys.exit("LAYOUT.txt contains CR")
if not raw.endswith(b"\n"):
    sys.exit("LAYOUT.txt is not LF-terminated")
text = raw.decode("utf-8")
line_re = re.compile(
    r"^tab=(\d+) bin=(\S+) x=(\d+) y=(\d+) w=(\d+) h=(\d+) focus=([01]) split=(none|h|v)$")
lines = text.splitlines()
if len(lines) != 2:
    sys.exit("LAYOUT.txt has %d lines, want 2" % len(lines))
parsed = []
for line in lines:
    m = line_re.match(line)
    if not m:
        sys.exit("bad LAYOUT line: %r" % line)
    parsed.append(m.groups())
ids = {parsed[0][0], parsed[1][0]}
if len(ids) != 2:
    sys.exit("tab ids not unique: %s" % (ids,))
bins = {parsed[0][1], parsed[1][1]}
if bins != {"GOCALC.ELF", "NOTE.ELF"}:
    sys.exit("bins %s want GOCALC.ELF and NOTE.ELF" % (bins,))
for row in parsed:
    if row[2:6] != ("0", "0", "1280", "720") or row[7] != "none":
        sys.exit("last dump must be unsplit full-viewport, got %s" % (row,))
foci = {parsed[0][6], parsed[1][6]}
if foci != {"0", "1"}:
    sys.exit("need one focused tab, focus bits %s" % (foci,))
print("LAYOUT.txt n=2 unsplit 1280x720 bins=%s focus ok" % ",".join(sorted(bins)))
PY

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-session-ok' --timeout 300

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'gotabwm: settings wm=none'
# M120b (#2559): `mode=restore` still names the decode (the strip came from
# the file), and `session reexec n=` is the live half — the seat re-exec'd
# the recorded bin and the app's own declare adopted the row in place, so
# the window id is a REAL kernel id (< 0x100), not the placeholder.
vgate_assert 02 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert 02 serial-contains 'gotabwm: session titles=notes.txt pin=0 active=0'
vgate_assert 02 serial-contains 'gotabwm: session freeze n=0'
vgate_assert 02 serial-contains 'gotabwm: session reexec n=1'
vgate_assert 02 serial-contains 'gotabwm: session exec NOTE.ELF'
# The re-exec'd app really hosted: its own declare is what opened the tab.
vgate_assert 02 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert 02 serial-count 'gotabwm: tab open id=' 1
vgate_assert 02 serial-contains 'gotabwm: session live n=1'
vgate_assert 02 serial-contains 'gotabwm: order ids='
vgate_assert 02 serial-contains 'pin=0'
vgate_assert 02 serial-contains 'gotabwm: rail n=1 focus='
vgate_assert 02 serial-contains 'gotabwm: layout file=/host/SELFTEST/LAYOUT.txt'
# The card's ID bound: nothing the second boot treats as a live window is
# >= 0x100 — the placeholder only ever existed between load and declare.
vgate_assert 02 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
bad = []
for m in re.finditer(
        r"^gotabwm: (?:tab open|tab focus|tab close|host focus|host view|host close|rpc declare|rpc attach) id=(\d+)",
        ser, re.M):
    if int(m.group(1)) >= 0x100:
        bad.append(m.group(0))
if bad:
    sys.exit("placeholder ids on live-window paths: %s" % bad)
print("every live-window id on boot 02 is < 0x100")
PY
# A live restored tab still never splits (that path needs two live rows
# the user made), and its teardown close is real.
vgate_assert 02 serial-absent 'gotabwm: split '
vgate_assert 02 serial-contains 'gotabwm: tab close id='
vgate_assert 02 serial-absent 'gotabwm: session bad'
vgate_assert 02 share-contains SELFTEST/LAYOUT.txt 'bin=NOTE.ELF'
vgate_assert 02 python <<'PY'
import os, re, sys
p = os.path.join(os.environ["VG_SHARE"], "SELFTEST/LAYOUT.txt")
raw = open(p, "rb").read()
if b"\r" in raw or not raw.endswith(b"\n"):
    sys.exit("LAYOUT.txt encoding")
line_re = re.compile(
    r"^tab=(\d+) bin=(\S+) x=(\d+) y=(\d+) w=(\d+) h=(\d+) focus=([01]) split=(none|h|v)$")
lines = raw.decode("utf-8").splitlines()
if len(lines) != 1:
    sys.exit("LAYOUT.txt has %d lines, want 1" % len(lines))
parsed = [line_re.match(line) for line in lines]
if not all(parsed):
    sys.exit("bad LAYOUT line in %r" % lines)
ids = [parsed[0].group(1)]
if ids == ["256"] or int(ids[0]) >= 256:
    sys.exit("restored id %s still the placeholder — the settle republish "
             "must carry the live window id (<0x100)" % ids)
bins = [parsed[0].group(2)]
if bins != ["NOTE.ELF"]:
    sys.exit("bins %s want NOTE.ELF" % bins)
if parsed[0].group(8) != "none":
    sys.exit("restore dump must be unsplit")
if parsed[0].group(7) != "1":
    sys.exit("the restored tab must be the focused one, focus=%s" % parsed[0].group(7))
print("LAYOUT.txt restore n=1 id=%s live (<0x100) unsplit" % ids[0])
# Boot 03 must not restore+re-exec the Calc/notes.txt session rows.
stale = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
try:
    os.remove(stale)
except FileNotFoundError:
    sys.exit("SESSION.TABS missing after restore (boot 02)")
print("cleared SESSION.TABS for boot 03")
PY
vgate_assert 02 serial-contains 'gotabwm: host done'
vgate_assert 02 serial-contains 'gotabwm: close'
vgate_assert 02 serial-contains 'gotabwm OK'
vgate_assert 02 serial-contains 'rx-gotabwm-session-ok'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --script '$RUN_DIR/script-03.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-apps-ok' --timeout 300

vgate_assert 03 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 03 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 03 serial-contains 'gotabwm: registered'
vgate_assert 03 serial-contains 'gotabwm: settings wm=none'
vgate_assert 03 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 03 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 03 serial-contains 'goedit: open id='
vgate_assert 03 serial-contains 'goedit: declare accepted'
vgate_assert 03 serial-contains 'goedit: present'
vgate_assert 03 serial-contains 'goedit: read /host/EDIT/SEED.TXT n=10'
vgate_assert 03 serial-contains 'goterm: open id='
vgate_assert 03 serial-contains 'goterm: declare accepted'
vgate_assert 03 serial-contains 'goterm: attached'
vgate_assert 03 serial-count 'gotabwm: tab open id=' 2
vgate_assert 03 serial-contains 'gotabwm: rail n=2 focus='
vgate_assert 03 serial-contains 'gotabwm: tab focus id='
vgate_assert 03 serial-absent 'gotabwm: session load n='
vgate_assert 03 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
edit = ser.find("goedit: present")
term = ser.find("goterm: attached")
close = ser.find("gotabwm: tab close id=")
if edit < 0 or term < 0:
    sys.exit("missing app syscall markers")
if close < 0:
    sys.exit("no tab close")
if not (edit < close and term < close):
    sys.exit("an app was closed before both were alive (edit=%d term=%d close=%d)" %
             (edit, term, close))
print("GOEDIT present and GOTERM attached before first tab close")
PY
vgate_assert 03 serial-contains 'gotabwm: layout file=/host/SELFTEST/LAYOUT.txt'
vgate_assert 03 share-contains SELFTEST/LAYOUT.txt 'bin=GOEDIT.ELF'
vgate_assert 03 share-contains SELFTEST/LAYOUT.txt 'bin=GOTERM.ELF'
vgate_assert 03 python <<'PY'
import os, re, sys
p = os.path.join(os.environ["VG_SHARE"], "SELFTEST/LAYOUT.txt")
raw = open(p, "rb").read()
if b"\r" in raw or not raw.endswith(b"\n"):
    sys.exit("LAYOUT.txt encoding")
line_re = re.compile(
    r"^tab=(\d+) bin=(\S+) x=(\d+) y=(\d+) w=(\d+) h=(\d+) focus=([01]) split=(none|h|v)$")
lines = raw.decode("utf-8").splitlines()
if len(lines) != 2:
    sys.exit("LAYOUT.txt has %d lines, want 2" % len(lines))
parsed = []
for line in lines:
    m = line_re.match(line)
    if not m:
        sys.exit("bad LAYOUT line: %r" % line)
    parsed.append(m.groups())
bins = {parsed[0][1], parsed[1][1]}
if bins != {"GOEDIT.ELF", "GOTERM.ELF"}:
    sys.exit("bins %s want GOEDIT.ELF and GOTERM.ELF" % (bins,))
for row in parsed:
    if row[2:6] != ("0", "0", "1280", "720") or row[7] != "none":
        sys.exit("last dump must be unsplit full-viewport, got %s" % (row,))
foci = {parsed[0][6], parsed[1][6]}
if foci != {"0", "1"}:
    sys.exit("need one focused tab, focus bits %s" % (foci,))
print("LAYOUT.txt n=2 unsplit 1280x720 bins=GOEDIT.ELF,GOTERM.ELF")
PY
vgate_assert 03 serial-count 'gotabwm: tab close id=' 2
vgate_assert 03 serial-contains 'gotabwm: rail n=1 focus='
vgate_assert 03 serial-contains 'gotabwm: tabs empty'
vgate_assert 03 serial-contains 'goedit: close'
vgate_assert 03 serial-contains 'goterm: close'
vgate_assert 03 serial-contains 'gotabwm: host done'
vgate_assert 03 serial-contains 'gotabwm: close'
vgate_assert 03 serial-contains 'gotabwm OK'
vgate_assert 03 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 03 serial-contains 'rx-gotabwm-apps-ok'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 serial-absent 'newosproc: sys_thread create failed'

# Run 04 must start on an EMPTY strip: run 03's two-tab choreography writes
# SESSION.TABS (M62e), and a later boot that restores it re-execs the
# recorded bins (M120b) AND sets stripDone. Same clear go-wm-tabs already
# does before run 03.
vgate_assert 03 python <<'PY'
import os, sys
stale = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
if os.path.exists(stale):
    os.remove(stale)
    print("cleared SESSION.TABS for run 04")
PY

# ---------------------------------------------------------------------------
# Run 04 (M71e / #1564, M48 BT6): the frozen badge, end to end.
#
# Two clients as in run 01. `ctrl-shift-f` is Zig's BT6 binding; GOTABWM's
# only other ctrl-shift letter chords then were ctrl-shift-p (pin — the
# M121a palette's chord now) and friends.
#
# M79g (#1718): the chords are anchored on pin-stay's own marker — NOT on a
# client-side marker like `note: tab-aware`. The two execs are unordered
# (SPEC.md: `exec` returns at spawn), so whichever client the seat adopts
# last holds focus at client-anchor time, and an injected chord can beat
# the seat's focus transition. applyPinStay pins the title-"Calc" tab
# wherever it sits, toggles focus away, then RESTORES focus to the pinned
# tab — so after `gotabwm: pin id=` the focused tab is deterministically
# the pinned Calc regardless of declare order. `alt-tab` then toggles
# focus to the unpinned text client (two tabs, wrap toggle), and
# `ctrl-shift-f` freezes NOTE deterministically, well inside the
# choreography's hidChordHold (32 ticks), long before the closes.
#
# This is a BADGE, not a lock: the run also asserts the frozen tab is still
# closed by the ordinary choreography (the `tab close` count below), because
# Zig's close path checks `frozen` nowhere and GOTABWM must not start.
vgate_file script-04.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-04.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
exec NOTE.ELF
EOF

vgate_file script3-04.txt <<'EOF'
wm
dui
echo rx-gotabwm-freeze-ok
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --via-virtio \
    --script '$RUN_DIR/script-04.txt' \
    --script2 '$RUN_DIR/script2-04.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'alt-tab,ctrl-shift-f' \
    --input-chords-after 'gotabwm: pin id=' \
    --script3 '$RUN_DIR/script3-04.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-freeze-ok' --timeout 300

vgate_assert 04 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 04 serial-contains 'gotabwm: registered'
vgate_assert 04 serial-contains 'gotabwm: alt-tab id='
vgate_assert 04 serial-contains 'gotabwm: freeze id='
vgate_assert 04 serial-absent 'gotabwm: thaw id='
vgate_assert 04 serial-contains 'gotabwm: session write n=2'
vgate_assert 04 serial-count 'gotabwm: tab close id=' 2
vgate_assert 04 serial-contains 'gotabwm: tabs empty'
vgate_assert 04 serial-contains 'gotabwm OK'
vgate_assert 04 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 04 serial-contains 'rx-gotabwm-freeze-ok'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 python <<'PY'
import os, sys
# The frozen bit must actually be ON DISK: this is the half of the card that
# was missing (the codec knew 0x02; GOTABWM dropped it on encode AND decode).
# M79g (#1718): the closes persist now, so what is on disk when the boot ends
# is the ONE tab the choreography left, and it is the frozen one — the chord
# is anchored on the client pin-stay does not pin (see the run's header).
# Offsets match tabsv2.go: header 6, title 32 -> flags at 6+32=38, bin at 51.
p = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
try:
    b = open(p, "rb").read()
except FileNotFoundError:
    sys.exit("SESSION.TABS missing on the share")
if len(b) < 6 + 69:
    sys.exit("SESSION.TABS too short: %d bytes" % len(b))
if b[0] != 2 or b[2] != 1:
    sys.exit("version=%d count=%d want 2/1" % (b[0], b[2]))
flags = b[38]
if flags & 0x02 == 0:
    sys.exit("flags=%#x: the frozen badge did not survive to disk" % flags)
title = b[6:38].split(b"\x00", 1)[0].decode()
bin0 = b[51:75].split(b"\x00", 1)[0].decode()
if bin0 != "NOTE.ELF":
    sys.exit("bin %r want NOTE.ELF (the frozen tab is the text client)" % bin0)
print("SESSION.TABS flags=%#x frozen record=0 title=%s bin=%s" % (flags, title, bin0))
PY

# Run 05 needs the same empty strip as run 04 (run 04 just wrote a session).
vgate_assert 04 python <<'PY'
import os, sys
stale = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
if os.path.exists(stale):
    os.remove(stale)
    print("cleared SESSION.TABS for run 05")
PY

# ---------------------------------------------------------------------------
# Run 05 (M71e / #1564): the empty-strip start surface, as PIXELS.
#
# Seat-only, no client, no click. The seat paints the surface on every tick
# with an empty strip and prints `gotabwm: start-surface` once. The screenshot
# is taken at the rx marker below, NOT at `gotabwm: present`: the host's
# framebuffer grab races the guest's present, so a capture keyed to that line
# reads the pre-paint buffer about half the time (observed 2026-09-21 — two
# runs with identical serial, one showing Bg across the whole panel rect and
# one Surface). Triggering script3 from `gotabwm: present` and capturing on its
# echo puts many ticks between the paint and the grab, which is the idiom
# go-wm-seat run 03 already uses.
#
# The panel rect is centred: (1280-336)/2=472, (720-76)/2=322.
vgate_file script-05.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-05.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-05.txt <<'EOF'
wm
dui
echo rx-gotabwm-start-ok
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --screenshot-after 'rx-gotabwm-start-ok' \
    --via-virtio \
    --script '$RUN_DIR/script-05.txt' \
    --script2 '$RUN_DIR/script2-05.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-05.txt' \
    --script3-after 'gotabwm: present' \
    --script-expect 'rx-gotabwm-start-ok' --timeout 300

vgate_assert 05 serial-contains 'gotabwm: registered'
vgate_assert 05 serial-contains 'gotabwm: start-surface'
vgate_assert 05 serial-absent 'gotabwm: session load n='
vgate_assert 05 serial-absent 'gotabwm: tab open id='
# No click in this run: the frame must be the bare empty-strip desktop.
vgate_assert 05 serial-absent 'gotabwm: launcher open n='
vgate_assert 05 serial-absent 'gotabwm: ptr'
# This run ends at the rx marker (the seat never exits), so no `gotabwm OK`
# and no `wm: unregistered` here: run 06 owns both, because its script3 fires
# on the seat's exit rather than on `gotabwm: present`.
vgate_assert 05 serial-contains 'rx-gotabwm-start-ok'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
vgate_assert 05 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
surf = next((i for i, l in enumerate(ser) if l == "gotabwm: start-surface"), -1)
rx = next((i for i, l in enumerate(ser) if l == "rx-gotabwm-start-ok"), -1)
if surf < 0:
    sys.exit("no start-surface marker")
if rx <= surf:
    sys.exit("rx marker precedes the surface paint (surf@%d rx@%d)" % (surf, rx))
print("start-surface@%d, capture marker@%d (%d lines later)" % (surf, rx, rx - surf))
PY
# The glob must name the MARKER capture, not the periodic one: `--screenshot-after`
# writes `<base>-after.png` while the fixed 5/10/15 s captures write
# `<base>-<t>s.png`. The 15s frame is taken AFTER the click opened the launcher,
# whose own panel covers the start surface (observed 2026-09-21).
vgate_assert 05 snapshot 'screen-05-after*' <<'PY'
import sys, zlib, struct
from collections import Counter
path = sys.argv[1]
d = open(path, "rb").read()
if d[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("not a PNG")
pos = 8; idat = b""; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack(">I4s", d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b"IHDR":
        w, h, bd, ct = struct.unpack(">IIBB", data[:10])
    elif typ == b"IDAT":
        idat += data
    pos += 12 + ln
raw = zlib.decompress(idat)
bpp = 4 if ct == 6 else 3
stride = w * bpp
out = bytearray(); prev = bytearray(stride); i = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line
def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]
def near(rgb, token, tol=3):
    return all(abs(a - b) <= tol for a, b in zip(rgb, token))
# Tokens (theme.Dark): Surface 0x222d35, Bg 0x182026, Accent 0x3b82f6.
# The capture applies a small colour-space shift, hence tol=3 (measured in
# M71c: ChromeBg 0x11171c read back as 0x12171c).
surface = (0x22, 0x2d, 0x35)
bg = (0x18, 0x20, 0x26)
accent = (0x3b, 0x82, 0xf6)
scale = w / 1280.0
x0, y0, pw, ph = 472, 322, 336, 76
panel = Counter()
for y in range(int(y0 * scale), int((y0 + ph) * scale)):
    for x in range(int(x0 * scale), int((x0 + pw) * scale)):
        panel[px(x, y)] += 1
if not panel:
    sys.exit("empty panel rect")
modal, mn = panel.most_common(1)[0]
if not near(modal, surface):
    sys.exit("panel modal %r is not Surface %r" % (modal, surface))
# The desktop outside the panel (and clear of the bottom-right chrome panel)
# must still be the blank Bg fill — the surface is painted OVER it, not instead.
desk = Counter()
for y in range(int(420 * scale), int(520 * scale)):
    for x in range(int(80 * scale), int(400 * scale)):
        desk[px(x, y)] += 1
dmodal, _ = desk.most_common(1)[0]
if not near(dmodal, bg):
    sys.exit("desktop modal %r is not Bg %r" % (dmodal, bg))
# The 2px accent rule on the panel's left edge is the seat's identity mark and
# the pixel anchor that proves this is seat chrome, not a hosted app window.
#
# It is tested by BLUE DOMINANCE, not a token match: the capture's shift is
# large on saturated blue (measured 2026-09-21: Accent 0x3b82f6 = (59,130,246)
# reads back as (78,128,238) at the rule's centre — +19 red — because a 2px
# rule at scale 2 lands on fractional pixels and blends with its neighbours).
# Nothing else on this frame is blue-dominant: Bg and Surface are dark grey
# and the text is near-white.
#
# M104e (#2272): the sample column moved one pixel right. The plate now
# carries the §2.2 1px Border stroke on its silhouette, so the outermost
# column is the border and the accent rule is column x0+1 — the same rule,
# one column in, through the shared rounded plate.
n = 0
for y in range(int((y0 + 2) * scale), int((y0 + ph - 2) * scale)):
    r, g, b = px(int((x0 + 1) * scale), y)
    if b > 150 and b > r + 40 and b > g + 40:
        n += 1
if n == 0:
    sys.exit("no accent rule on the start surface's left edge")

# M104e (#2272): the panel is a §2.5 floating plate — it casts the shared
# drop shadow onto the uniform Bg desktop, and its §2.2 radius cuts the
# corners. The shadow band below the silhouette (dy=4, blur 16) darkens
# Bg by ~25% on every channel; the corner pixel sits outside the
# silhouette, so it cannot read Surface.
band = Counter()
for y in range(int((y0 + ph + 6) * scale), int((y0 + ph + 18) * scale)):
    for x in range(int((x0 + 40) * scale), int((x0 + pw - 40) * scale)):
        band[px(x, y)] += 1
if not band:
    sys.exit("empty shadow band below the start surface")
bmodal, bn = band.most_common(1)[0]
if not all(m <= c - 3 for m, c in zip(bmodal, bg)):
    sys.exit("no shadow under the start surface: band modal %r is not "
             "darker than the desktop %r" % (bmodal, bg))
corner = px(int((x0 + 1) * scale), int((y0 + 1) * scale))
if near(corner, surface, 4):
    sys.exit("the start surface's top-left corner reads Surface %r - "
             "the plate is not rounded" % (corner,))
print("start surface: panel modal %r (%d px), desktop %r, accent rule %d rows, "
      "shadow band %r (%d px), corner %r" % (modal, mn, dmodal, n, bmodal, bn, corner))
PY

# ---------------------------------------------------------------------------
# Run 06 (M71e / #1564): the surface's affordance — the panel IS the click
# target. Run 05 proves the pixels; this run proves the hit-test, and it carries
# no pixel assertion of its own because the launcher it opens covers the panel
# (launchX=240 launchW=800 vs the panel's 472..808 x 322..398). Serial only,
# so the present-race that forced run 05 onto an rx marker cannot bite here.
vgate_assert 05 python <<'PY'
import os, sys
stale = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
if os.path.exists(stale):
    os.remove(stale)
    print("cleared SESSION.TABS for run 06")
PY

vgate_file script-06.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-06.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-06.txt <<'EOF'
wm
dui
echo rx-gotabwm-start-click-ok
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio \
    --script '$RUN_DIR/script-06.txt' \
    --script2 '$RUN_DIR/script2-06.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '640,360,c' \
    --pointer-virtio-after 'gotabwm: present' \
    --script3 '$RUN_DIR/script3-06.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-start-click-ok' --timeout 300

vgate_assert 06 serial-contains 'gotabwm: registered'
vgate_assert 06 serial-contains 'gotabwm: start-surface'
vgate_assert 06 serial-absent 'gotabwm: session load n='
vgate_assert 06 serial-absent 'gotabwm: tab open id='
vgate_assert 06 serial-contains 'gotabwm: ptr'
# The click at 640,360 lands inside the panel rect (472..808 x 322..398) and
# opens the launcher the surface advertises.
vgate_assert 06 serial-contains 'gotabwm: launcher open n='
vgate_assert 06 serial-contains 'gotabwm OK'
vgate_assert 06 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 06 serial-contains 'rx-gotabwm-start-click-ok'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'
vgate_assert 06 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
surf = next((i for i, l in enumerate(ser) if l == "gotabwm: start-surface"), -1)
launch = next((i for i, l in enumerate(ser) if l.startswith("gotabwm: launcher open n=")), -1)
if surf < 0:
    sys.exit("no start-surface marker")
if launch < 0:
    sys.exit("the click did not open the launcher")
if launch <= surf:
    sys.exit("launcher opened before the surface was painted (surf@%d launch@%d)" % (surf, launch))
print("start-surface@%d then launcher open@%d" % (surf, launch))
PY

# Run 07 needs the same empty strip as run 06 (no session is written by a
# seat-only run, but a reused share must not restore one either).
vgate_assert 06 python <<'PY'
import os
stale = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
if os.path.exists(stale):
    os.remove(stale)
    print("cleared SESSION.TABS for run 07")
PY

# ---------------------------------------------------------------------------
# Run 07 (M79c / #1706): the sash drag, end to end.
#
# Two clients as in run 01, because the split needs exactly two tabs. The
# split comes from the ctrl-shift-v cycle chord — live mode's only split
# entry (the choreography is demo-only) — fired on `gotabwm: rail n=2`,
# inside the choreography's 32-tick HID hold. The drag,
# `--pointer-virtio '640,100,d;800,100,u'`, is anchored on
# `gotabwm: split v`: the down lands on the midpoint divider (x=640,
# y=100 — below the rail, clear of the bottom chrome), the release at
# x=800 commits the sash with the 6 px gutter. The run ends at its own rx
# marker while the seat is still up (the run-05 shape), so the
# choreography never fires: no reorder, no unsplit, no session write, and
# LAYOUT.txt keeps the sash geometry.
#
# Timing honesty: ticks advance only on the 1 Hz COMPOSITE_TICK and the
# choreography steps split -> unsplit on consecutive ticks (~1 s apart),
# while a via-virtio drag takes ~10 s of guest time. Anchoring the drag on
# the choreography's own split could never land — which is why the chord
# (and the hold window it splits inside of) is part of this card.
vgate_file script-07.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-07.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
exec NOTE.ELF
EOF

vgate_file script3-07.txt <<'EOF'
wm
dui
echo rx-gotabwm-sash-ok
EOF

vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --via-virtio \
    --script '$RUN_DIR/script-07.txt' \
    --script2 '$RUN_DIR/script2-07.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-v' \
    --input-chords-after 'gotabwm: rail n=2' \
    --pointer-virtio '640,100,d;800,100,u' \
    --pointer-virtio-after 'gotabwm: split v' \
    --script3 '$RUN_DIR/script3-07.txt' \
    --script3-after 'gotabwm: sash v from=640 to=800' \
    --script-expect 'rx-gotabwm-sash-ok' --timeout 300

vgate_assert 07 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 07 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 07 serial-contains 'gotabwm: registered'
vgate_assert 07 serial-contains 'gotabwm: settings wm=none'
vgate_assert 07 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 07 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert 07 serial-contains 'gotabwm: rail n=2 focus='
vgate_assert 07 serial-contains 'gocalc: declare accepted'
vgate_assert 07 serial-contains 'note: tab-aware (full-viewport)'
# The cycle chord split, verbatim through the choreography's own applySplit.
vgate_assert 07 serial-contains 'gotabwm: split v'
vgate_assert 07 serial-contains 'x=640 y=0 w=640 h=720'
# The drag committed: divider 640 -> 800, the 6 px gutter as geometry.
vgate_assert 07 serial-contains 'gotabwm: sash v from=640 to=800'
vgate_assert 07 serial-contains 'x=0 y=0 w=797 h=720'
vgate_assert 07 serial-contains 'x=803 y=0 w=477 h=720'
# Both panes moved, so the hosted client observed its WIN_RESIZE after the
# sash marker (the kernel pushes it once applyRect returns).
vgate_assert 07 serial-contains 'note: resize relayout'
vgate_assert 07 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def first(prefix, start=0):
    for i in range(start, len(ser)):
        if prefix in ser[i]:
            return i
    sys.exit("missing " + prefix)
split = first("gotabwm: split v")
sash = first("gotabwm: sash v from=640 to=800")
# NOTE relayouts on every resize — the chord split relayouts it too — so the
# sash's WIN_RESIZE is the first relayout AFTER the sash marker, not the
# first in the log.
relayout = first("note: resize relayout", sash + 1)
if not (split < sash < relayout):
    sys.exit("split@%d sash@%d relayout@%d must order split < sash < relayout" % (
        split, sash, relayout))
print("split@%d sash@%d relayout@%d" % (split, sash, relayout))
PY
# Pair each sash-run layout dump with the applied pane line dumpTab prints
# next. Every pair must match exactly (integer gutter, no remainder).
vgate_assert 07 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lay_re = re.compile(
    r"^gotabwm: layout tab=(\d+) bin=\S+ x=(\d+) y=(\d+) w=(\d+) h=(\d+) ")
pane_re = re.compile(
    r"^gotabwm: pane id=(\d+) x=(\d+) y=(\d+) w=(\d+) h=(\d+)$")
n = 0
pending = None
for line in ser.splitlines():
    lm = lay_re.match(line)
    if lm:
        pending = lm
        continue
    pm = pane_re.match(line)
    if not pm:
        continue
    if pending is None:
        sys.exit("pane line with no preceding layout dump: " + line)
    if pending.group(1) != pm.group(1):
        sys.exit("layout tab=%s paired with pane id=%s" % (
            pending.group(1), pm.group(1)))
    for i, name in ((2, "x"), (3, "y"), (4, "w"), (5, "h")):
        a, b = int(pending.group(i)), int(pm.group(i))
        if a != b:
            sys.exit("tab %s %s dump=%d applied=%d (want exact)" % (
                pending.group(1), name, a, b))
    n += 1
    pending = None
if n != 4:
    sys.exit("only %d layout/pane pairs (want 4: chord split + sash x2)" % n)
print("layout vs applied pane: %d pairs exact" % n)
PY
# The sash consumed its press: no rail click/focus change, no reorder, and
# the choreography never fired (this run lives entirely inside its hold).
vgate_assert 07 serial-contains 'gotabwm: ptr'
vgate_assert 07 serial-absent 'gotabwm: rail-click id='
vgate_assert 07 serial-absent 'gotabwm: reorder '
vgate_assert 07 serial-absent 'gotabwm: unsplit'
# M79g (#1718): the choreography never fired, so no CLOSE was ever written —
# the file still names both clients (the declares wrote it). That is the
# positive form of the old `session write` absence: the run ends inside the
# hold with the two-tab strip intact.
vgate_assert 07 serial-contains 'gotabwm: session write n=2'
vgate_assert 07 python <<'PY'
import os, sys
p = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
try:
    b = open(p, "rb").read()
except FileNotFoundError:
    sys.exit("SESSION.TABS missing on the share")
if len(b) < 6 + 69 * 2:
    sys.exit("SESSION.TABS too short: %d bytes" % len(b))
if b[0] != 2 or b[2] != 2:
    sys.exit("version=%d count=%d want 2/2 (no close ran)" % (b[0], b[2]))
bins = sorted([b[51:75].split(b"\x00", 1)[0].decode(),
               b[51 + 69:75 + 69].split(b"\x00", 1)[0].decode()])
if bins != ["GOCALC.ELF", "NOTE.ELF"]:
    sys.exit("bins %s want GOCALC.ELF + NOTE.ELF" % bins)
print("SESSION.TABS n=2 bins=%s: the run ended before any close" % ",".join(bins))
PY
# LAYOUT.txt is the sash geometry: the run ends before anything rewrites it.
vgate_assert 07 serial-contains 'gotabwm: layout file=/host/SELFTEST/LAYOUT.txt'
vgate_assert 07 share-contains SELFTEST/LAYOUT.txt 'split=v'
vgate_assert 07 share-contains SELFTEST/LAYOUT.txt 'x=803 y=0 w=477 h=720'
vgate_assert 07 python <<'PY'
import os, re, sys
p = os.path.join(os.environ["VG_SHARE"], "SELFTEST/LAYOUT.txt")
try:
    raw = open(p, "rb").read()
except FileNotFoundError:
    sys.exit("SELFTEST/LAYOUT.txt missing on the share")
if b"\r" in raw:
    sys.exit("LAYOUT.txt contains CR")
if not raw.endswith(b"\n"):
    sys.exit("LAYOUT.txt is not LF-terminated")
text = raw.decode("utf-8")
line_re = re.compile(
    r"^tab=(\d+) bin=(\S+) x=(\d+) y=(\d+) w=(\d+) h=(\d+) focus=([01]) split=(none|h|v)$")
lines = text.splitlines()
if len(lines) != 2:
    sys.exit("LAYOUT.txt has %d lines, want 2" % len(lines))
parsed = []
for line in lines:
    m = line_re.match(line)
    if not m:
        sys.exit("bad LAYOUT line: %r" % line)
    parsed.append(m.groups())
bins = {parsed[0][1], parsed[1][1]}
if bins != {"GOCALC.ELF", "NOTE.ELF"}:
    sys.exit("bins %s want GOCALC.ELF and NOTE.ELF" % (bins,))
geoms = {tuple(row[2:6]) for row in parsed}
if geoms != {("0", "0", "797", "720"), ("803", "0", "477", "720")}:
    sys.exit("sash geometry %s want 797/803 gutter pair" % (geoms,))
if not all(row[7] == "v" for row in parsed):
    sys.exit("split field must stay v, got %s" % ([row[7] for row in parsed],))
foci = {parsed[0][6], parsed[1][6]}
if foci != {"0", "1"}:
    sys.exit("need one focused tab, focus bits %s" % (foci,))
print("LAYOUT.txt sash v 797/803 bins=GOCALC.ELF,NOTE.ELF focus ok")
PY
# This run ends at the rx marker (the seat never exits), so no `gotabwm OK`
# and no `wm: unregistered` here — the run-05 shape.
vgate_assert 07 serial-contains 'rx-gotabwm-sash-ok'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'exited status=139'

# Run 08 must start on an empty strip: run 07 now leaves a two-tab session
# (M79g — the declares write it), which a restore would re-exec (M120b).
# Same clear the spec already does between the earlier runs.
vgate_assert 07 python <<'PY'
import os, sys
stale = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
if os.path.exists(stale):
    os.remove(stale)
    print("cleared SESSION.TABS for run 08")
PY

# --- M79e (#1708): the nav round trip, over the real wire -------------------
# GOFILES.ELF is the adopter: it declares a nav on every directory change and
# polls the seat for a back/forward target. Two declares give the history
# something to step back through, and the Ctrl+Shift+[ chord is the seat-side
# affordance (M48/BT5's own binding).
#
# The two strokes are DELIBERATELY in two stages, each gated on a marker the
# app prints. The cv-input transport paces chords at a fixed 0.25 s and the
# guest tick is ~1 s on VZ, so a single 'return,ctrl-shift-[' batch could
# deliver the chord BEFORE the seat had processed the declare it depends on —
# a race that would make the gate intermittently green. Gating the chord on
# `gofiles: nav declare` is the same discipline the other runs use: the stage
# gate waits on guest output, never on the script's own echo.
#
# exec-order: assert-proven -- the run ends on `rx-gotabwm-nav-ok`, which only
# script3 prints, and script3 is held behind `gofiles: nav back to`, a marker
# only the hosted app can print (so a broken round trip fails the run rather
# than being skipped).
vgate_file script-08.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-08.txt <<'EOF'
dui focus 0
exec GOFILES.ELF /host/NAV
EOF

vgate_file script3-08.txt <<'EOF'
wm
dui
echo rx-gotabwm-nav-ok
EOF

vgate_run 08 -- \
    --screen '$RUN_DIR/screen-08' \
    --via-virtio \
    --script '$RUN_DIR/script-08.txt' \
    --script2 '$RUN_DIR/script2-08.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-string $'\n' \
    --input-string-after 'gofiles: ready' \
    --input-chords 'ctrl-shift-[' \
    --input-chords-after 'gofiles: nav declare /host/NAV/SUBDIR' \
    --script3 '$RUN_DIR/script3-08.txt' \
    --script3-after 'gofiles: nav back to /host/NAV' \
    --script-expect 'rx-gotabwm-nav-ok' --timeout 300

vgate_assert 08 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 08 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 08 serial-contains 'gotabwm: registered'
vgate_assert 08 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 08 serial-contains 'gofiles: declare accepted'
# The client's first declare: the app's start path, announced once the model
# exists (never before).
vgate_assert 08 serial-contains 'gofiles: nav declare /host/NAV'
# The descent: the Return the gate typed opened the one directory in NAV.
vgate_assert 08 serial-contains 'gofiles: cd /host/NAV/SUBDIR'
vgate_assert 08 serial-contains 'gofiles: nav declare /host/NAV/SUBDIR'
# The SEAT's half. Both markers are printed only after the state moved: the
# declare reached the per-tab history, and the chord queued a target.
vgate_assert 08 serial-contains 'gotabwm: nav declare id='
vgate_assert 08 serial-contains 'gotabwm: nav back id='
vgate_assert 08 serial-contains 'gotabwm: nav poll id='
# The client half: the app received a path and ACTED on it. This marker is
# the proof the round trip closed, because it can only print after the app
# read a path out of the ack title.
vgate_assert 08 serial-contains 'gofiles: nav back to /host/NAV'
vgate_assert 08 serial-contains 'rx-gotabwm-nav-ok'
vgate_assert 08 serial-absent '\[EXC\]'
vgate_assert 08 serial-absent '[EXC] parking:'

# The round trip itself, as an ordering + payload-identity check. The seat's
# back target MUST be byte-identical to the path the client first declared —
# that is the whole claim of the card: a path declared by the app comes back
# to the same app through the ack title. Also pinned: a deduped re-declare
# must not print, so exactly two seat-side nav declares exist.
vgate_assert 08 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()

first = re.search(r"gofiles: nav declare (/host/NAV)\b", ser)
assert first, "the client never declared its start path"
p0 = first.group(1)

second = re.search(r"gofiles: nav declare (/host/NAV/SUBDIR)\b", ser)
assert second, "the client never declared the descended path"
p1 = second.group(1)
assert p0 != p1, "both declares carry the same path; there is no history to step"

# The seat recorded the descended path (kind 9 reached applyRPC) and queued
# the older one for the chord.
seat_rec = re.search(r"gotabwm: nav declare id=(\d+) path=" + re.escape(p1), ser)
assert seat_rec, "the seat never recorded the client's declare (kind 9 arm)"
wid = seat_rec.group(1)

back = re.search(r"gotabwm: nav back id=(\d+) path=(\S+)", ser)
assert back, "the chord did not queue a back target"
assert back.group(1) == wid, "the chord queued for a different window (%s vs %s)" % (back.group(1), wid)
assert back.group(2) == p0, "back target %r is not the path the client declared (%r)" % (back.group(2), p0)

# The poll arm answered, with the SAME path, in the ack.
poll = re.search(r"gotabwm: nav poll id=(\d+) path=(\S+)", ser)
assert poll, "the poll arm (kind 10) never answered"
assert poll.group(1) == wid, "the poll answered for a different window"
assert poll.group(2) == p0, "the poll handed back %r, want %r" % (poll.group(2), p0)

# And the client acted on it.
back_to = ser.find("gofiles: nav back to " + p0)
assert back_to >= 0, "the client never received the target"

# Ordering: nothing may be answered before it was asked.
i_start = ser.find("gofiles: nav declare " + p0)
i_cd = ser.find("gofiles: cd " + p1)
i_rec = ser.find(seat_rec.group(0))
i_back = ser.find(back.group(0))
i_poll = ser.find(poll.group(0))
for name, i in (("start declare", i_start), ("cd", i_cd), ("seat record", i_rec),
                ("chord back", i_back), ("poll answer", i_poll), ("client act", back_to)):
    assert i >= 0, "%s marker missing" % name
assert i_start < i_cd < i_rec < i_back < i_poll < back_to, (
    "nav chain out of order: start=%d cd=%d record=%d back=%d poll=%d act=%d"
    % (i_start, i_cd, i_rec, i_back, i_poll, back_to))

# Exactly TWO seat-side declares: the app's initial path plus the descent.
# A third would mean a re-declare of the current path was recorded instead of
# deduped (the seat's consecutive-dedupe rule).
n_decl = len(re.findall(r"gotabwm: nav declare id=", ser))
assert n_decl == 2, "expected exactly 2 seat-side nav declares, saw %d" % n_decl

print("M79e nav round trip OK: %s -> %s -> back to %s, window id=%s, "
      "exactly %d declares (dedupe held)" % (p0, p1, p0, wid, n_decl))
PY

# --- M79g (#1718): SESSION.TABS records what the USER did -------------------
#
# Two boots on the same share, both LIVE (the GOTABWM.DEMO trigger is removed
# before the exec, the go-wm-seat run 05 pattern): live mode is the product,
# and it is also deterministic here — no bounded choreography is racing the
# HID chain with its own reorder/pin/close steps.
#
# Boot 09 is the mutation boot. GOCALC+NOTE declare, then BY HAND:
#   ctrl-1            focus the left cell (Calc — NOTE's declare took focus)
#   ctrl-shift-n      pin it (M121a: pin moved off ctrl-shift-p, which the
#                     command palette now owns)
#   ctrl-shift-f      freeze it
#   rail drag 0 -> 1  move it to the right, past the unpinned tab
# Each of those is a real mutation and each one writes SESSION.TABS as it
# happens (write-through), so the file is already correct when the run ends
# at its own rx marker with the seat still up — no clean exit needed, which
# is the whole point of writing through instead of saving on exit.
#
# The expected end state, and why it is a real test: the pin normalizes
# pinned-left, and the DRAG then moves that pinned, frozen tab to index 1.
# So the file must read notes.txt (unpinned) BEFORE Calc (pinned+frozen) —
# the reverse of the declare order, which a file written from the declare
# order alone could never produce.
vgate_file script-09.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-09.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
exec NOTE.ELF
EOF

vgate_file script3-09.txt <<'EOF'
wm
dui
echo rx-gotabwm-session-write-ok
EOF

vgate_run 09 -- \
    --screen '$RUN_DIR/screen-09' \
    --via-virtio \
    --script '$RUN_DIR/script-09.txt' \
    --script2 '$RUN_DIR/script2-09.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-1,ctrl-shift-n,ctrl-shift-f' \
    --input-chords-after 'note: tab title notes.txt' \
    --pointer-virtio '100,8,d;700,8,u' \
    --pointer-virtio-after 'gotabwm: freeze id=' \
    --script3 '$RUN_DIR/script3-09.txt' \
    --script3-after 'gotabwm: reorder 0->1' \
    --script-expect 'rx-gotabwm-session-write-ok' --timeout 300

vgate_assert 09 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 09 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 09 serial-contains 'gotabwm: registered'
# The product mode: no bounded loop, nothing auto-closes. (Run 09 removes
# the trigger, so run 10 boots live too — one share, one removal.)
vgate_assert 09 serial-contains 'gotabwm: mode live'
vgate_assert 09 serial-contains 'gotabwm: settings wm=none'
vgate_assert 09 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 09 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert 09 serial-contains 'gotabwm: rail n=2 focus='
vgate_assert 09 serial-contains 'gocalc: declare accepted'
vgate_assert 09 serial-contains 'note: tab-aware (full-viewport)'
# M79d: NOTE renamed itself, which is the title the session must carry.
vgate_assert 09 serial-contains 'gotabwm: title id='
vgate_assert 09 serial-contains 'note: tab title notes.txt'
# The three chords + the drag, each after the previous one's own marker.
vgate_assert 09 serial-contains 'gotabwm: tab focus id='
vgate_assert 09 serial-contains 'gotabwm: pin id='
vgate_assert 09 serial-contains 'gotabwm: freeze id='
vgate_assert 09 serial-contains 'gotabwm: order ids='
vgate_assert 09 serial-contains 'pin=1,0'
vgate_assert 09 serial-contains 'pin=0,1'
vgate_assert 09 serial-contains 'gotabwm: reorder 0->1'
# Write-through: every one of those mutations published the file. Six writes
# minimum, each proven by its own marker above: the two kind-8 declares
# (GOCALC n=1, NOTE n=2), NOTE's kind-11 retitle (the `gotabwm: title id=`
# line — SetTitle has no same-value short-circuit, so it always persists),
# then pin, freeze and the drag reorder. A missing write with the markers
# present would mean a mutation the file does not carry — the crash window
# this card exists to close.
vgate_assert 09 serial-count 'gotabwm: session write n=' 6
vgate_assert 09 serial-contains 'gotabwm: session write n=2'
# Live mode closed nothing, so no close ever rewrote the file.
vgate_assert 09 serial-absent 'gotabwm: tab close id='
vgate_assert 09 serial-absent 'gotabwm: host close id='
vgate_assert 09 serial-contains 'rx-gotabwm-session-write-ok'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 serial-absent 'exited status=139'

# The file itself: the ORDER, the pin bit, the frozen badge and the live
# title, byte-level on the share (offsets per tabsv2.go: header 6, record
# 69 = title 32 | flags 1 | group 12 | bin 24).
#
# The strip order is resolved from the seat's own markers, not assumed:
# script2's two execs are unordered (SPEC.md — `exec` returns at spawn), so
# whichever client binds first owns slot 0 and the rail drag moves THAT tab
# right. The chord/pin/freeze choreography is positional (ctrl-1 focuses
# slot 0), so either declare order is a legal run; the file must equal the
# strip the seat reported in its last `order ids=` line either way.
vgate_assert 09 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
orders = re.findall(r"gotabwm: order ids=(\d+),(\d+) pin=", ser)
if not orders:
    sys.exit("no order ids= line in serial")
slot0, slot1 = int(orders[-1][0]), int(orders[-1][1])
calc_m = re.search(r"gocalc: open id=(\d+)", ser)
note_m = re.search(r"note: open id=(\d+)", ser)
if not calc_m or not note_m:
    sys.exit("missing app open markers in serial")
app = {int(calc_m.group(1)): ("Calc", "GOCALC.ELF"),
       int(note_m.group(1)): ("notes.txt", "NOTE.ELF")}
if slot0 not in app or slot1 not in app:
    sys.exit("order ids %d,%d not the two clients %s" % (slot0, slot1, sorted(app)))
want_titles = [app[slot0][0], app[slot1][0]]
want_bins = [app[slot0][1], app[slot1][1]]

p = os.path.join(os.environ["VG_SHARE"], "SESSION.TABS")
try:
    b = open(p, "rb").read()
except FileNotFoundError:
    sys.exit("SESSION.TABS missing on the share")
if len(b) < 6 + 69 * 2:
    sys.exit("SESSION.TABS too short: %d bytes" % len(b))
if b[0] != 2:
    sys.exit("version %d want 2" % b[0])
if b[2] != 2:
    sys.exit("count %d want 2" % b[2])
if b[1] != 2:
    sys.exit("active+1 = %d want 2 (the dragged tab stays focused)" % b[1])
recs = []
for i in (0, 1):
    off = 6 + i * 69
    recs.append((b[off:off + 32].split(b"\x00", 1)[0].decode(),
                 b[off + 32],
                 b[off + 45:off + 69].split(b"\x00", 1)[0].decode()))
titles, flags, bins = ([r[0] for r in recs], [r[1] for r in recs], [r[2] for r in recs])
if titles != want_titles:
    sys.exit("titles %s want %s (file must match the seat's order)" % (titles, want_titles))
if flags[0] != 0:
    sys.exit("record 0 flags %#x want 0 (unpinned, thawed)" % flags[0])
if flags[1] != 0x03:
    sys.exit("record 1 flags %#x want 0x03 (pinned|frozen)" % flags[1])
if bins != want_bins:
    sys.exit("bins %s want %s (identity follows the tab)" % (bins, want_bins))
print("SESSION.TABS: %s(0x00,%s) then %s(0x03,%s), "
      "active=%s — the user's order, pin and badge" % (
          titles[0], bins[0], titles[1], bins[1], titles[1]))
PY

# Ordering: the last publish came after the last mutation, so the file is
# not a stale snapshot taken earlier in the boot.
vgate_assert 09 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
i_write = ser.rfind("gotabwm: session write n=")
i_reorder = ser.find("gotabwm: reorder 0->1")
i_freeze = ser.find("gotabwm: freeze id=")
for name, i in (("reorder", i_reorder), ("freeze", i_freeze), ("last write", i_write)):
    if i < 0:
        sys.exit("missing " + name)
if not (i_freeze < i_reorder < i_write):
    sys.exit("order wrong: freeze=%d reorder=%d write=%d" % (i_freeze, i_reorder, i_write))
print("last session write at %d, after reorder at %d" % (i_write, i_reorder))
PY

# --- M79g (#1718) + M120b (#2559): the second boot re-execs it --------------
#
# No HID, no scripted clients: the seat boots on the share run 09 left and
# must re-execute the recorded bins, keeping the ORDER, the pin bit, the
# frozen badge and the focus the user actually left. `mode=restore` still
# names the decode; `session reexec n=2` is the exec fan-out, `session live
# n=2` is every pid's declare having re-inhabited its row, and the ids that
# land on the strip are real kernel window ids (< 0x100 — re-exec, not
# placeholder accumulation). The rx marker waits on `session live` so the
# serial and LAYOUT.txt both describe the settled strip.
vgate_file script-10.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-10.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-10.txt <<'EOF'
wm
dui
echo rx-gotabwm-session-restore-ok
EOF

vgate_run 10 -- \
    --screen '$RUN_DIR/screen-10' \
    --via-virtio --cvc-snap \
    --snapshot-after 'gotabwm: present' \
    --snapshot-out '$RUN_DIR/snap-10' \
    --script '$RUN_DIR/script-10.txt' \
    --script2 '$RUN_DIR/script2-10.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-10.txt' \
    --script3-after 'gotabwm: session live n=2' \
    --script-expect 'rx-gotabwm-session-restore-ok' --timeout 300

vgate_assert 10 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 10 serial-contains 'gotabwm: registered'
vgate_assert 10 serial-contains 'gotabwm: mode live'
vgate_assert 10 serial-contains 'gotabwm: session load n=2 mode=restore'
# M120b (#2559): the re-exec half — both recorded bins exec'd, both apps
# really hosted (their own declare markers, not the seat's), and the settle
# reported both rows live.
vgate_assert 10 serial-contains 'gotabwm: session reexec n=2'
vgate_assert 10 serial-contains 'gotabwm: session live n=2'
vgate_assert 10 serial-contains 'gotabwm: session exec NOTE.ELF'
vgate_assert 10 serial-contains 'gotabwm: session exec GOCALC.ELF'
vgate_assert 10 serial-count 'gotabwm: rpc declare id=' 2
vgate_assert 10 serial-count 'gotabwm: tab open id=' 2
# The order line the seat restored. Which tab sits in slot 0 is decided by
# run 09's unsequenced execs (SPEC.md: `exec` returns at spawn), so the
# expected line is derived from the SESSION.TABS run 09 left on the share —
# the seat's restore report must faithfully echo the file it loaded.
vgate_assert 10 python <<'PY'
import os, sys
b = open(os.path.join(os.environ["VG_SHARE"], "SESSION.TABS"), "rb").read()
titles, pins = [], []
for i in range(b[2]):
    off = 6 + i * 69
    titles.append(b[off:off + 32].split(b"\x00", 1)[0].decode())
    pins.append("1" if b[off + 32] & 1 else "0")
line = "gotabwm: session titles=%s pin=%s active=%d" % (
    ",".join(titles), ",".join(pins), b[1] - 1)
ser = open(os.environ["VG_SER"], errors="replace").read()
if line not in ser:
    sys.exit("restored titles line %r (from the file) missing from serial" % line)
print("restore echo matches SESSION.TABS: %s" % line)
PY
vgate_assert 10 serial-contains 'gotabwm: session freeze n=1'
vgate_assert 10 serial-contains 'gotabwm: order ids='
vgate_assert 10 serial-contains 'pin=0,1'
vgate_assert 10 serial-contains 'gotabwm: rail n=2 focus='
vgate_assert 10 serial-contains 'gotabwm: layout file=/host/SELFTEST/LAYOUT.txt'
# M120b (#2559): the settle is the boundary — every id the strip treated as
# live is < 0x100, and the placeholder rows that waited on declares never
# became kernel windows themselves.
vgate_assert 10 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
bad = []
for m in re.finditer(
        r"^gotabwm: (?:tab open|tab focus|tab close|host focus|host view|host close|rpc declare|rpc attach|alt-tab) id=(\d+)",
        ser, re.M):
    if int(m.group(1)) >= 0x100:
        bad.append(m.group(0))
if bad:
    sys.exit("placeholder ids on live-window paths: %s" % bad)
print("every live-window id on boot 10 is < 0x100")
PY
vgate_assert 10 serial-absent 'gotabwm: split '
vgate_assert 10 serial-absent 'gotabwm: tab close id='
vgate_assert 10 serial-absent 'gotabwm: session bad'
vgate_assert 10 serial-absent 'gotabwm: first-boot workspace'
vgate_assert 10 serial-contains 'rx-gotabwm-session-restore-ok'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 serial-absent 'exited status=139'
vgate_assert 10 python <<'PY'
import os, re, sys
# LAYOUT.txt is the settle dump: the two restored rows carrying their real
# window ids, in the recorded order.
p = os.path.join(os.environ["VG_SHARE"], "SELFTEST/LAYOUT.txt")
try:
    raw = open(p, "rb").read()
except FileNotFoundError:
    sys.exit("SELFTEST/LAYOUT.txt missing on the share")
line_re = re.compile(
    r"^tab=(\d+) bin=(\S+) x=(\d+) y=(\d+) w=(\d+) h=(\d+) focus=([01]) split=(none|h|v)$")
lines = raw.decode("utf-8").splitlines()
if len(lines) != 2:
    sys.exit("LAYOUT.txt has %d lines, want 2" % len(lines))
parsed = [line_re.match(line) for line in lines]
if not all(parsed):
    sys.exit("bad LAYOUT line in %r" % lines)
ids = [int(parsed[0].group(1)), int(parsed[1].group(1))]
if any(i >= 256 for i in ids):
    sys.exit("restored ids %s still placeholders — re-exec must land live "
             "window ids (<0x100)" % ids)
if len(set(ids)) != 2:
    sys.exit("live ids not unique: %s" % ids)
# Row order follows run 09's file — which tab led is whichever client won
# the unsequenced exec/bind race, so compare against SESSION.TABS itself.
sb = open(os.path.join(os.environ["VG_SHARE"], "SESSION.TABS"), "rb").read()
want_bins = [sb[6 + i * 69 + 45:6 + i * 69 + 69].split(b"\x00", 1)[0].decode()
             for i in range(sb[2])]
bins = [parsed[0].group(2), parsed[1].group(2)]
if bins != want_bins:
    sys.exit("bins %s want %s (the order run 09 persisted)" % (bins, want_bins))
if any(row[8] != "none" for row in parsed):
    sys.exit("restore dump must be unsplit")
print("LAYOUT.txt restore n=2 live ids=%s bins=%s in the recorded order" % (ids, bins))
PY

# M104e (#2272): the rail on the restored strip, as PIXELS. Two cells of
# 640px under the 22px strip; the file's active=2 focuses cell 1. The card's
# §2.3.6 pinned geometry is the claim: the focused cell is a Selection fill
# carrying the 3px Accent left-edge marker, the idle cell keeps BtnIdle
# with NO marker, and every cell carries the close glyph (VirelaiChrome
# window-close on a fonted seat — the bitmap 'x' here, since this share
# stages no FONTS.TXT: the run 01 `gotabwm: fonts` assert names that
# degrade). Cell 1's frozen badge is run 09's pin+freeze left behind.
#
# The snapshot rides the kind-4 channel (`--snapshot-after 'gotabwm:
# present'`): the marker is once-guarded behind the seat's first presented
# frame, so the scanout it streams already carries the rail. BGRX raw, so
# the probes are exact token matches — no capture shift, no scale.
vgate_assert 10 snapshot 'snap-10-*.raw' <<'PY'
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

ACCENT = (0x3b, 0x82, 0xf6)
SELECTION = (0x2a, 0x44, 0x60)
BTN_IDLE = (0x2d, 0x37, 0x48)
WARNING = (0xf5, 0x9e, 0x0b)
BG = (0x18, 0x20, 0x26)
MUTED = (0x94, 0xa3, 0xb8)

# Cell 1 (x 640..1279) is focused: the 3px Accent marker rides its left
# edge at x 641..643 for the full strip height (paintRail: marker at
# x+1, w=3 over the cell's Selection fill).
marker = 0
for y in range(22):
    for x in (641, 642, 643):
        if px(x, y) == ACCENT:
            marker += 1
if marker < 3 * 20:
    sys.exit("only %d accent-marker px on the focused rail cell - the "
             "3px selection marker did not paint" % marker)
assert px(900, 11) == SELECTION, \
    "focused rail cell interior %r is not Selection %r" \
    % (px(900, 11), SELECTION)

# Cell 0 (x 0..639) is idle: BtnIdle face, a Bg trough at its left edge,
# and NO accent marker — the marker is focus visibility, not decoration.
assert px(300, 11) == BTN_IDLE, \
    "idle rail cell interior %r is not BtnIdle %r" % (px(300, 11), BTN_IDLE)
assert px(1, 11) == BTN_IDLE, \
    "the idle cell's left edge %r is not its face - a marker leaked" % (px(1, 11),)
assert px(0, 11) == BG and px(640, 11) == BG, \
    "the 1px trough between cells is not Bg: %r %r" % (px(0, 11), px(640, 11))

# Every cell carries the close glyph in its close zone — Muted ink on the
# cell face (Danger only while the pointer hovers the zone, and no pointer
# ran in this boot). Cell 0's bitmap 'x' lands at 626..633 x 7..14; the
# PUA glyph lands in the same zone on a fonted seat, so the probe counts
# non-face pixels, not a bitmap mask.
def glyph_strokes(x0, y0, face):
    n = 0
    for y in range(y0, y0 + 8):
        for x in range(x0, x0 + 8):
            c = px(x, y)
            if c != face:
                if c != MUTED:
                    sys.exit("close-zone pixel (%d,%d) is %r, want %r or the "
                             "cell face %r" % (x, y, c, MUTED, face))
                n += 1
    return n
g0 = glyph_strokes(626, 7, BTN_IDLE)
if g0 < 4:
    sys.exit("only %d close-glyph px in cell 0's close zone - the "
             "window-close control did not paint" % g0)
g1 = glyph_strokes(1266, 7, SELECTION)
if g1 < 4:
    sys.exit("only %d close-glyph px in cell 1's close zone" % g1)

# Cell 1's frozen badge survived the restore: the 4px Warning strip inset
# 4px at the cell's right edge (x 1275..1278, rows 4..17) — the pin+freeze
# run 09 persisted.
badge = sum(1 for y in range(4, 18) for x in range(1275, 1279)
            if px(x, y) == WARNING)
if badge < 40:
    sys.exit("only %d frozen-badge px on the restored cell - the badge "
             "did not repaint" % badge)
print("rail: %d marker px, Selection/BtnIdle faces, close glyphs %d+%d, "
      "frozen badge %d px" % (marker, g0, g1, badge))
PY

# --- M97g-F2 (#2080): WM_RPC sender authentication --------------------------
#
# The mailbox is any-to-any and carries no sender identity, so a raw frame
# proves nothing about who sent it. The Go seat binds each window to a
# session token the window's kernel-registered owner alone can obtain (the
# challenge rides the window title — slot 61 is owner-restricted — and the
# seat reads it back with wmctl cmd 14). WMRPCPROBE.ELF is the in-guest
# attacker: it binds its OWN window honestly (proving the owner path works
# end to end on the real wire), then sprays forged SetTitle frames at every
# other user window id — bare frames, guessed-token frames, and an echo of a
# challenge it was issued but cannot prove. Zero forged frames may apply,
# and the seat's `rpc refuse`/`rpc bind` markers record both halves.
#
# #3048 adds the pre-queued-echo leg: a forged echo quoting the challenge
# but claiming a reply_to the owner-written proof title does not name.
# The proof title commits to a pid, so the forged echo is refused without
# consuming the challenge and the honest echo that lands next still binds
# (the third `rpc bind` below).
#
# Ordering: the probe execs only after `note: tab-aware`, so NOTE's own bind
# has already landed and the spray hits at least one genuinely bound foreign
# window.
vgate_file script-11.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-11.txt <<'EOF'
dui focus 0
exec NOTE.ELF
EOF

vgate_file script3-11.txt <<'EOF'
exec WMRPCPROBE.ELF
EOF

vgate_run 11 -- \
    --screen '$RUN_DIR/screen-11' \
    --script '$RUN_DIR/script-11.txt' \
    --script2 '$RUN_DIR/script2-11.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-11.txt' \
    --script3-after 'note: tab-aware (full-viewport)' \
    --script-expect 'wmrpcprobe: auth probe ok' --timeout 300

vgate_assert 11 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 11 serial-contains 'gotabwm: registered'
vgate_assert 11 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert 11 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert 11 serial-contains 'exec: loaded WMRPCPROBE.ELF'
# Both honest clients bound (NOTE's declare, then the probe's), plus the
# probe's honest re-bind after the forged echo was starved: three binds.
vgate_assert 11 serial-count 'gotabwm: rpc bind id=' 3
# The honest legs still work under the authenticated protocol.
vgate_assert 11 serial-contains 'wmrpcprobe: bound id='
vgate_assert 11 serial-contains 'wmrpcprobe: title ok'
# The attack legs: every forged frame refused, none applied.
vgate_assert 11 serial-contains 'wmrpcprobe: foreign applied=0 refused='
vgate_assert 11 serial-contains 'wmrpcprobe: echo refused id='
vgate_assert 11 serial-contains 'wmrpcprobe: bad-token refused'
# M137a: the bound kind-29 from a non-AGENTD principal is refused by
# name — applied=0 reaches the probe AND the R2 marker prints.
vgate_assert 11 serial-contains 'gotabwm: agent_input_denied'
vgate_assert 11 serial-contains 'wmrpcprobe: agent-input refused'
# #3048: the forged echo claiming a foreign reply_to is refused while a
# genuine owner-made proof title stands, and the honest echo still binds.
vgate_assert 11 serial-contains 'wmrpcprobe: forged-echo refused id='
vgate_assert 11 serial-contains 'wmrpcprobe: rebind ok'
vgate_assert 11 serial-contains 'wmrpcprobe: auth probe ok'
vgate_assert 11 serial-contains 'gotabwm: rpc refuse id='
vgate_assert 11 serial-absent 'wmrpcprobe: FAIL'
vgate_assert 11 serial-absent '[EXC] parking:'
vgate_assert 11 serial-absent 'exited status=139'


# ---------------------------------------------------------------------------
# Run 12 (M125a / #2586): save_state on the snapshot chord — the app's blob
# lands in SESSION.TABS's app_state trailer. GOTABAPP.ELF is the protocol's
# live client: the seat posts the kind-20 notice, the app publishes
# `u8 appver | u32 len | blob` at /host/APPSTATE.<id>, posts the request, and
# the seat validates, stores, deletes the staging file and republishes the
# session. The file's trailer is asserted byte-level: `AS` magic, section ver
# 1, one entry {index, appver=1, len=30, the demo's literal bytes}.

vgate_file script-12.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-12.txt <<'EOF'
dui focus 0
exec GOTABAPP.ELF
EOF

vgate_file script3-12.txt <<'EOF'
wm
dui
echo rx-gotabwm-state-save-ok
EOF

vgate_run 12 -- \
    --screen '$RUN_DIR/screen-12' \
    --via-virtio \
    --script '$RUN_DIR/script-12.txt' \
    --script2 '$RUN_DIR/script2-12.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-s' \
    --input-chords-after 'gotabapp: present' \
    --script3 '$RUN_DIR/script3-12.txt' \
    --script3-after 'gotabwm: snapshot saved' \
    --script-expect 'rx-gotabwm-state-save-ok' --timeout 300

vgate_assert 12 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 12 serial-contains 'gotabwm: registered'
vgate_assert 12 serial-contains 'exec: loaded GOTABAPP.ELF'
vgate_assert 12 serial-contains 'gotabapp: declare accepted'
# A fresh tab honestly has no stored state — the restore request is the
# honest empty answer, never a fabricated blob.
vgate_assert 12 serial-absent 'gotabapp: state restored'
vgate_assert 12 serial-absent 'gotabapp: state mismatch'
# The snapshot chord asked the bound tab; the app staged 30 bytes at appver
# 1 and the seat stored them (and republished the session carrying them).
vgate_assert 12 serial-contains 'gotabwm: state ask id='
vgate_assert 12 serial-contains 'gotabwm: state save id='
vgate_assert 12 serial-contains 'len=30 ver=1'
vgate_assert 12 serial-contains 'gotabwm: snapshot saved '
vgate_assert 12 serial-absent 'gotabwm: state drop'
# Byte-level on the share: the .tabs v2 trailer framing and the demo's
# literal blob — byte identity is the card's claim, not a checksum.
vgate_assert 12 python <<'PY'
import os, sys
b = open(os.path.join(os.environ["VG_SHARE"], "SESSION.TABS"), "rb").read()
if b[0] != 2 or b[2] != 1:
    sys.exit("SESSION.TABS header ver=%d count=%d" % (b[0], b[2]))
off = 6 + 69
if len(b) < off + 6 + 8 + 30:
    sys.exit("SESSION.TABS too short for a state trailer: %d" % len(b))
if b[off:off+2] != b"AS" or b[off+2] != 1 or b[off+3] != 1:
    sys.exit("app_state header %r" % b[off:off+6])
ent = b[off+6:off+14]
if ent[0] != 0 or ent[1] != 1:
    sys.exit("app_state entry index=%d appver=%d" % (ent[0], ent[1]))
ln = int.from_bytes(ent[4:8], "little")
blob = b[off+14:off+14+ln]
if blob != b"gotabapp state v1: hello strip":
    sys.exit("blob %r is not the demo's bytes" % blob)
print("SESSION.TABS app_state: idx=0 appver=1 len=%d blob=%r" % (ln, blob))
PY
vgate_assert 12 serial-contains 'rx-gotabwm-state-save-ok'
vgate_assert 12 serial-absent '[EXC] parking:'
vgate_assert 12 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 13 (M125a / #2586): the restore half — a FRESH boot loads the file run
# 12 left, re-execs GOTABAPP.ELF, the app's restore_state request gets the
# blob back byte-intact and its own callback says so.

vgate_file script-13.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-13.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-13.txt <<'EOF'
wm
dui
echo rx-gotabwm-state-restore-ok
EOF

vgate_run 13 -- \
    --screen '$RUN_DIR/screen-13' \
    --via-virtio \
    --script '$RUN_DIR/script-13.txt' \
    --script2 '$RUN_DIR/script2-13.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-13.txt' \
    --script3-after 'gotabapp: state restored' \
    --script-expect 'rx-gotabwm-state-restore-ok' --timeout 300

vgate_assert 13 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 13 serial-contains 'gotabwm: registered'
vgate_assert 13 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert 13 serial-contains 'gotabwm: session reexec n=1'
vgate_assert 13 serial-contains 'gotabwm: session exec GOTABAPP.ELF'
vgate_assert 13 serial-contains 'gotabwm: session live n=1'
# The seat staged the stored blob for the re-exec'd tab and the app's own
# RestoreState verified it byte-for-byte — the full seat leg.
vgate_assert 13 serial-contains 'gotabwm: state restore id='
vgate_assert 13 serial-contains 'len=30 ver=1'
vgate_assert 13 serial-contains 'gotabapp: state restored len=30'
vgate_assert 13 serial-absent 'gotabapp: state mismatch'
vgate_assert 13 serial-absent 'gotabwm: state drop'
vgate_assert 13 serial-contains 'rx-gotabwm-state-restore-ok'
vgate_assert 13 serial-absent '[EXC] parking:'
vgate_assert 13 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 14 (M125b / #2587): GOEDIT as the state client — a REAL session, not
# the demo's literal bytes. On "alpha\nbeta\ngamma\n": goto line 2, find
# "mma" (lands the match selected at 13..16), X replaces it, ctrl-z + a
# shifted redo walk both rings, ctrl-shift-m + two lefts leave a 2-byte
# selection, ctrl-s publishes, and the snapshot chord asks the seat to take
# the blob — `state save` carries GOEDIT's appver=1 envelope into the
# SESSION.TABS AS trailer.

vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
ed = os.path.join(share, "EDIT")
os.makedirs(ed, exist_ok=True)
with open(os.path.join(ed, "STATE.TXT"), "wb") as f:
    f.write(b"alpha\nbeta\ngamma\n")
print("seeded EDIT/STATE.TXT (17 bytes)")
PY

vgate_file script-14.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-14.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF /host/EDIT/STATE.TXT
EOF

vgate_file script3-14.txt <<'EOF'
wm
dui
echo rx-goedit-state-save-ok
EOF

vgate_run 14 -- \
    --screen '$RUN_DIR/screen-14' \
    --via-virtio \
    --script '$RUN_DIR/script-14.txt' \
    --script2 '$RUN_DIR/script2-14.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-g,2,return,ctrl-f,m,m,a,return,X,ctrl-z,ctrl-shift-z,ctrl-shift-m,left,left,ctrl-s,ctrl-shift-s' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script3-14.txt' \
    --script3-after 'gotabwm: snapshot saved' \
    --script-expect 'rx-goedit-state-save-ok' --timeout 300

vgate_assert 14 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 14 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 14 serial-contains 'goedit: declare accepted'
vgate_assert 14 serial-contains 'goedit: read /host/EDIT/STATE.TXT n=17'
# A fresh tab has no stored state — the restore request is the honest empty
# answer, never a fabricated blob.
vgate_assert 14 serial-absent 'goedit: state restored'
# The session's receipts: the goto, the landed-and-selected find, the typed
# replace, both ring walks, the mark selection, and the save.
vgate_assert 14 serial-contains 'goedit: goto line=2 offset=6'
vgate_assert 14 serial-contains "goedit: find 'mma' hit=1/1"
vgate_assert 14 serial-contains 'goedit: undo n=0 cur=16'
vgate_assert 14 serial-contains 'goedit: redo n=0 cur=14'
vgate_assert 14 serial-contains 'goedit: mark set'
vgate_assert 14 serial-contains 'goedit: status line=3/4 col=2 sel=2 *'
vgate_assert 14 serial-contains 'goedit: saved /host/EDIT/STATE.TXT n=15'
# The snapshot chord asked the bound tab; the seat stored the blob at
# appver=1 and republished the session carrying it.
vgate_assert 14 serial-contains 'gotabwm: state ask id='
vgate_assert 14 serial-contains 'gotabwm: state save id='
vgate_assert 14 serial-contains ' ver=1'
vgate_assert 14 serial-contains 'gotabwm: snapshot saved '
vgate_assert 14 serial-absent 'gotabwm: state drop'
# Byte-level on the share: the AS trailer framing and a non-empty GOEDIT
# blob. The blob's internals are the app's own format — asserted by its
# markers and by run 15's restore, not decoded here.
vgate_assert 14 python <<'PY'
import os, sys
b = open(os.path.join(os.environ["VG_SHARE"], "SESSION.TABS"), "rb").read()
if b[0] != 2 or b[2] != 1:
    sys.exit("SESSION.TABS header ver=%d count=%d" % (b[0], b[2]))
off = 6 + 69
if len(b) < off + 6 + 8:
    sys.exit("SESSION.TABS too short for a state trailer: %d" % len(b))
if b[off:off+2] != b"AS" or b[off+2] != 1 or b[off+3] != 1:
    sys.exit("app_state header %r" % b[off:off+6])
ent = b[off+6:off+14]
if ent[0] != 0 or ent[1] != 1:
    sys.exit("app_state entry index=%d appver=%d" % (ent[0], ent[1]))
ln = int.from_bytes(ent[4:8], "little")
blob = b[off+14:off+14+ln]
if len(blob) != ln or ln == 0 or blob[0] != 1:
    sys.exit("blob len=%d fmtver=%d" % (len(blob), blob[0] if ln else -1))
print("SESSION.TABS app_state: idx=0 appver=1 len=%d (goedit fmt v1)" % ln)
PY
vgate_assert 14 serial-contains 'rx-goedit-state-save-ok'
vgate_assert 14 serial-absent '[EXC] parking:'
vgate_assert 14 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 15 (M125b / #2587): the restore half. A FRESH boot loads the file run
# 14 left, re-execs GOEDIT.ELF — bare bin, no argv: the blob's path field is
# the ONLY place the file survives — and the app's kind-21 request hands
# the envelope back. `goedit: state restored` reports the caret, the
# 12..14 selection, one undo op and both histories; a post-restore ctrl-z
# fires `undo n=0 cur=16` — proof the restored ring reverts, not just parses.

vgate_file script-15.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-15.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-15.txt <<'EOF'
wm
dui
echo rx-goedit-state-restore-ok
EOF

vgate_run 15 -- \
    --screen '$RUN_DIR/screen-15' \
    --via-virtio \
    --script '$RUN_DIR/script-15.txt' \
    --script2 '$RUN_DIR/script2-15.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-z' \
    --input-chords-after 'goedit: status line=3/4 col=2 sel=2' \
    --script3 '$RUN_DIR/script3-15.txt' \
    --script3-after 'goedit: undo n=0' \
    --script-expect 'rx-goedit-state-restore-ok' --timeout 300

vgate_assert 15 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 15 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert 15 serial-contains 'gotabwm: session reexec n=1'
vgate_assert 15 serial-contains 'gotabwm: session exec GOEDIT.ELF'
vgate_assert 15 serial-contains 'gotabwm: session live n=1'
# The path came from the blob: `session exec GOEDIT.ELF` re-execs the bare
# bin (no argv marker exists), yet the editor opened STATE.TXT — argv never
# exists on a restored session, so the blob is the only carrier.
vgate_assert 15 serial-contains 'goedit: read /host/EDIT/STATE.TXT n=15'
# The seat staged the blob; GOEDIT's own apply reports caret, selection,
# rings and histories.
vgate_assert 15 serial-contains 'gotabwm: state restore id='
vgate_assert 15 serial-contains ' ver=1'
vgate_assert 15 serial-contains 'goedit: state restored cur=12 sel=12..14 undo=1 redo=0 fh=1 gh=1'
vgate_assert 15 serial-absent 'goedit: state stale'
vgate_assert 15 serial-absent 'gotabwm: state drop'
# The restored status row: caret at 12 on line 3, two bytes selected, clean.
vgate_assert 15 serial-contains 'goedit: status line=3/4 col=2 sel=2'
# The restored undo ring is LIVE: ctrl-z reverts the saved op and lands the
# caret at the end of the recovered region.
vgate_assert 15 serial-contains 'goedit: undo n=0 cur=16'
vgate_assert 15 serial-contains 'rx-goedit-state-restore-ok'
vgate_assert 15 serial-absent '[EXC] parking:'
vgate_assert 15 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 16 (M125d / #2589): WEB as the state client — a real session, not the
# demo's literal bytes. WEB.ELF opens /host/FORM.HTML (taller than the 720
# CSS px viewport), pagedown leaves a real scroll offset, tab focuses the
# text input and five letters land in it, tab+space checks the checkbox,
# tab+down moves the select to "beta" — then ctrl-shift-s has the seat ask
# and the app stage its v1 blob: url + scroll + zoom + the field values.

vgate_file script-16.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-16.txt <<'EOF'
dui focus 0
exec WEB.ELF /host/FORM.HTML
EOF

vgate_file script3-16.txt <<'EOF'
wm
dui
echo rx-web-state-save-ok
EOF

vgate_run 16 -- \
    --screen '$RUN_DIR/screen-16' \
    --via-virtio \
    --script '$RUN_DIR/script-16.txt' \
    --script2 '$RUN_DIR/script2-16.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'pagedown,tab,h,e,l,l,o,tab,space,tab,down,ctrl-shift-s' \
    --input-chords-after 'web: ready' \
    --script3 '$RUN_DIR/script3-16.txt' \
    --script3-after 'gotabwm: snapshot saved' \
    --script-expect 'rx-web-state-save-ok' --timeout 300

vgate_assert 16 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 16 serial-contains 'gotabwm: registered'
vgate_assert 16 serial-contains 'exec: loaded WEB.ELF'
vgate_assert 16 serial-contains 'web: url /host/FORM.HTML'
vgate_assert 16 serial-contains 'web: ready'
# A fresh tab honestly has no stored state — the restore request is the
# honest empty answer, never a fabricated blob.
vgate_assert 16 serial-absent 'web: state restored'
vgate_assert 16 serial-absent 'web: state refused'
# The session's receipts: the scroll, and the snapshot chord's ask that
# the app answered — the seat stored WEB's appver=1 envelope.
vgate_assert 16 serial-contains 'gotabwm: state ask id='
vgate_assert 16 serial-contains 'gotabwm: state save id='
vgate_assert 16 serial-contains ' ver=1'
vgate_assert 16 serial-contains 'gotabwm: snapshot saved '
vgate_assert 16 serial-absent 'gotabwm: state drop'
# Byte-level on the share: the AS trailer framing plus the blob's own
# v1 header — url text, a real scroll offset, the 100% rung and all
# three serialized fields (text/hello, checkbox/checked, select/beta).
vgate_assert 16 python <<'PY'
import os, sys
b = open(os.path.join(os.environ["VG_SHARE"], "SESSION.TABS"), "rb").read()
if b[0] != 2 or b[2] != 1:
    sys.exit("SESSION.TABS header ver=%d count=%d" % (b[0], b[2]))
off = 6 + 69
if len(b) < off + 6 + 8:
    sys.exit("SESSION.TABS too short for a state trailer: %d" % len(b))
if b[off:off+2] != b"AS" or b[off+2] != 1 or b[off+3] != 1:
    sys.exit("app_state header %r" % b[off:off+6])
ent = b[off+6:off+14]
if ent[0] != 0 or ent[1] != 1:
    sys.exit("app_state entry index=%d appver=%d" % (ent[0], ent[1]))
ln = int.from_bytes(ent[4:8], "little")
blob = b[off+14:off+14+ln]
if len(blob) != ln or ln < 8:
    sys.exit("blob len=%d" % ln)
if blob[0] != 1 or blob[1] != 0:
    sys.exit("blob fmtVer=%d flags=%d" % (blob[0], blob[1]))
zoom = int.from_bytes(blob[2:4], "little")
scroll = int.from_bytes(blob[4:8], "little")
ul = int.from_bytes(blob[8:10], "little")
url = blob[10:10+ul]
if url != b"/host/FORM.HTML":
    sys.exit("blob url %r" % url)
nf = blob[10+ul]
if nf != 3:
    sys.exit("blob fields=%d want 3" % nf)
if zoom != 100 or scroll <= 0:
    sys.exit("zoom=%d scroll=%d" % (zoom, scroll))
print("SESSION.TABS app_state: web v1 len=%d url=%r scroll=%d zoom=%d fields=%d"
      % (ln, url, scroll, zoom, nf))
PY
vgate_assert 16 serial-contains 'rx-web-state-save-ok'
vgate_assert 16 serial-absent '[EXC] parking:'
vgate_assert 16 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 17 (M125d / #2589): the restore half. A FRESH boot loads the file run
# 16 left, re-execs WEB.ELF — bare bin, no argv exists on a re-exec — and
# the app's kind-21 request hands the envelope back. WEB navigates to the
# blob's url, and `web: state restored` reports the re-clamped scroll, the
# rung and 3/3 fields landed on the refetched page.

vgate_file script-17.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-17.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-17.txt <<'EOF'
wm
dui
echo rx-web-state-restore-ok
EOF

vgate_run 17 -- \
    --screen '$RUN_DIR/screen-17' \
    --via-virtio \
    --script '$RUN_DIR/script-17.txt' \
    --script2 '$RUN_DIR/script2-17.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-17.txt' \
    --script3-after 'web: state restored' \
    --script-expect 'rx-web-state-restore-ok' --timeout 300

vgate_assert 17 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 17 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert 17 serial-contains 'gotabwm: session reexec n=1'
vgate_assert 17 serial-contains 'gotabwm: session exec WEB.ELF'
vgate_assert 17 serial-contains 'gotabwm: session live n=1'
# The url came from the blob: `session exec WEB.ELF` re-execs the bare bin
# (no argv exists on a restored session), yet the browser opened FORM.HTML.
vgate_assert 17 serial-contains 'web: url /host/FORM.HTML'
vgate_assert 17 serial-contains 'gotabwm: state restore id='
vgate_assert 17 serial-contains ' ver=1'
vgate_assert 17 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(
    r"^web: state restored url=(\S+) scroll=(\d+) zoom=(\d+) forms=(\d+)/(\d+)$",
    ser, re.M)
if not m:
    sys.exit("missing 'web: state restored' line")
if m.group(1) != "/host/FORM.HTML":
    sys.exit("restored url " + m.group(1))
if int(m.group(2)) <= 0:
    sys.exit("restored scroll=%s want >0" % m.group(2))
if m.group(3) != "100":
    sys.exit("restored zoom=" + m.group(3))
if m.group(4) != "3" or m.group(5) != "3":
    sys.exit("restored forms=%s/%s want 3/3" % (m.group(4), m.group(5)))
print("web state restored: url=%s scroll=%s zoom=%s forms=%s/%s" % m.groups())
PY
vgate_assert 17 serial-absent 'web: state refused'
vgate_assert 17 serial-absent 'gotabwm: state drop'
vgate_assert 17 serial-contains 'rx-web-state-restore-ok'
vgate_assert 17 serial-absent '[EXC] parking:'
vgate_assert 17 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 18 (M125g / #2592): the session-fidelity acceptance — ONE live session
# carrying ALL THREE state clients at once, the shape a person actually
# leaves behind: a terminal mid-session, a browser on a page, an editor
# mid-edit.
#
#   GOTERM + WEB.ELF open first (one script2 — their strip order races but
#   nothing below reads it: NEITHER takes typed input). GOTERM's cwd/env/
#   scrollback ride /host/PROFILE.SH (the share's startup contract, staged
#   in setup — silent lines, so no `goterm: line` markers exist for them;
#   the blob's own decode in the python assert is the save-leg proof).
#   WEB's blob is argv state — url + zoom rung (scroll/forms already proven
#   field-level by runs 16/17).
#   script3 waits on `session write n=2` — the seat's republish after the
#   SECOND declare — so GOEDIT is provably the last exec: a new declare
#   takes focus (interop.go "New declares take focus"), which pins the
#   chord burst on the editor deterministically. 'z,z,z' lands in the
#   buffer (dirty, caret 3), then `ctrl-shift-s` asks every bound tab.
#
# The run's end IS the hard kill: the expect matches mid-session, VMRunner
# exits, and the machine stops existing — no suspend, no vzsave, nothing
# but the crash-safe SESSION.TABS publish crossing onto the share. Run 19
# is the restart half.
#
# exec-order: assert-proven -- the run ends on `gotabwm: snapshot saved`,
# which only the snapshot arm prints after its collect+publish; a client
# that never ran leaves the ask unanswered and the marker absent.

vgate_file script-18.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-18.txt <<'EOF'
dui focus 0
exec GOTERM.ELF
exec WEB.ELF /host/FORM.HTML
EOF

vgate_file script3-18.txt <<'EOF'
exec GOEDIT.ELF /host/EDIT/M125G.TXT
EOF

vgate_run 18 -- \
    --screen '$RUN_DIR/screen-18' \
    --via-virtio \
    --script '$RUN_DIR/script-18.txt' \
    --script2 '$RUN_DIR/script2-18.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-18.txt' \
    --script3-after 'gotabwm: session write n=2' \
    --input-chords 'z,z,z,ctrl-shift-s' \
    --input-chords-after 'goedit: present' \
    --script-expect 'gotabwm: snapshot saved' --timeout 300

vgate_assert 18 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 18 serial-contains 'gotabwm: registered'
vgate_assert 18 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 18 serial-contains 'goterm: declare accepted'
vgate_assert 18 serial-contains 'goterm: attached'
vgate_assert 18 serial-contains 'goterm: prompt'
vgate_assert 18 serial-contains 'exec: loaded WEB.ELF'
vgate_assert 18 serial-contains 'web: url /host/FORM.HTML'
vgate_assert 18 serial-contains 'web: ready'
vgate_assert 18 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 18 serial-contains 'goedit: declare accepted'
vgate_assert 18 serial-contains 'goedit: read /host/EDIT/M125G.TXT n=14'
vgate_assert 18 serial-contains 'goedit: present'
# Fresh tabs honestly answer no stored state — three empty restores.
vgate_assert 18 serial-absent 'state restored'
# The typed text landed BEFORE the ask: dirty buffer, caret at byte 3.
vgate_assert 18 serial-contains 'goedit: status line=2/2 col=4 *'
# The snapshot chord asked all three bound tabs; every one answered and
# the seat republished the session carrying all three blobs.
vgate_assert 18 serial-count 'gotabwm: state ask id=' 3
vgate_assert 18 serial-count 'gotabwm: state save id=' 3
vgate_assert 18 serial-contains 'gotabwm: session write n=3'
vgate_assert 18 serial-contains 'gotabwm: snapshot saved '
vgate_assert 18 serial-absent 'gotabwm: state drop'
# Byte-level on the share: the file the kill leaves behind — three v2
# records (one bin each), the AS trailer carrying one appver=1 blob per
# row, and GOTERM's blob decoded to the state PROFILE.SH produced.
vgate_assert 18 python <<'PY'
import os, sys
b = open(os.path.join(os.environ["VG_SHARE"], "SESSION.TABS"), "rb").read()
if b[0] != 2 or b[2] != 3:
    sys.exit("SESSION.TABS header ver=%d count=%d want v2 n=3"
             % (b[0], b[2]))
bins = []
for i in range(3):
    rec = b[6 + i * 69:6 + (i + 1) * 69]
    bins.append(rec[45:69].split(b"\x00")[0].decode())
off = 6 + 3 * 69
if b[off:off+2] != b"AS" or b[off+2] != 1 or b[off+3] != 3:
    sys.exit("app_state trailer %r want AS ver=1 n=3" % b[off:off+6])
p = off + 6
blobs = {}
for _ in range(3):
    ent = b[p:p+8]
    ln = int.from_bytes(ent[4:8], "little")
    blob = b[p+8:p+8+ln]
    if len(blob) != ln or ln == 0:
        sys.exit("entry idx=%d len=%d truncated" % (ent[0], ln))
    if ent[1] != 1:
        sys.exit("entry idx=%d appver=%d want 1" % (ent[0], ent[1]))
    blobs[bins[ent[0]]] = blob
    p += 8 + ln
for name in ("GOTERM.ELF", "WEB.ELF", "GOEDIT.ELF"):
    if name not in blobs:
        sys.exit("no app_state blob for %s (bins=%s)" % (name, bins))
# GOTERM v1: u8 fmt | u8 flags | u16 cwdLen | cwd | u16 envN | pairs |
# u32 scLen | scroll.
g = blobs["GOTERM.ELF"]
if g[0] != 1:
    sys.exit("goterm blob fmt=%d" % g[0])
cwdLen = int.from_bytes(g[2:4], "little")
cwd = g[4:4+cwdLen].decode()
if cwd != "/M125G":
    sys.exit("goterm blob cwd=%r want /M125G" % cwd)
envN = int.from_bytes(g[4+cwdLen:6+cwdLen], "little")
p = 6 + cwdLen
pairs = []
for _ in range(envN):
    pl = int.from_bytes(g[p:p+2], "little")
    p += 2
    pairs.append(g[p:p+pl].decode())
    p += pl
if "M125G_X=alive-7" not in pairs:
    sys.exit("goterm blob env=%r lost M125G_X" % pairs)
scLen = int.from_bytes(g[p:p+4], "little")
scroll = g[p+4:p+4+scLen]
if b"M125G-PROOF" not in scroll:
    sys.exit("goterm scrollback (%d B) lost the proof line" % scLen)
# WEB v1: u8 fmt | u8 flags | u16 zoom | u32 scroll | u16 urlLen | url...
w = blobs["WEB.ELF"]
ul = int.from_bytes(w[8:10], "little")
url = w[10:10+ul]
if w[0] != 1 or url != b"/host/FORM.HTML":
    sys.exit("web blob fmt=%d url=%r" % (w[0], url))
# GOEDIT v1: fmt byte + a non-empty blob; its field-level proof is the
# app's own restored marker in run 19, not a second decode here.
e = blobs["GOEDIT.ELF"]
if e[0] != 1:
    sys.exit("goedit blob fmt=%d" % e[0])
print("SESSION.TABS: 3 rows %s, AS n=3 all appver=1; goterm cwd=%r env=%d "
      "scroll=%dB; web url=%r; goedit len=%d"
      % (bins, cwd, envN, scLen, url, len(e)))
PY
vgate_assert 18 serial-absent '[EXC] parking:'
vgate_assert 18 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 19 (M125g / #2592): the restart half. A fresh boot of the same share
# decodes the file run 18's hard kill left behind, re-execs all three rows
# (bare bins — argv never survives, the blob is the only carrier), and each
# app's restore_state hands its envelope back. The per-app markers ARE the
# per-field proof: goterm reports the saved cwd/env/scroll tail, web the
# url it re-navigated to, goedit the caret and the live undo ring.
#
# script3 rides on `session live n=3` — the settle after every pending row
# adopted — and the run then holds the expect-tail window so the three
# post-adoption restore markers (each app's own pace) reach the serial log
# before teardown. A dropped row never lets the marker print: the run would
# time out, never silently pass.

vgate_file script-19.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-19.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-19.txt <<'EOF'
wm
dui
echo rx-m125g-back-ok
EOF

vgate_run 19 -- \
    --screen '$RUN_DIR/screen-19' \
    --via-virtio \
    --script '$RUN_DIR/script-19.txt' \
    --script2 '$RUN_DIR/script2-19.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-19.txt' \
    --script3-after 'gotabwm: session live n=3' \
    --script-expect 'rx-m125g-back-ok' --script-expect-tail 15 --timeout 300

vgate_assert 19 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 19 serial-contains 'gotabwm: registered'
# The restart: the kill-surviving file decoded, all three rows re-exec'd
# (session exec names the BIN, never the loader's `exec: loaded` — the
# seat's own spawn path carries no argv).
vgate_assert 19 serial-contains 'gotabwm: session load n=3 mode=restore'
vgate_assert 19 serial-contains 'gotabwm: session reexec n=3'
vgate_assert 19 serial-contains 'gotabwm: session exec GOTERM.ELF'
vgate_assert 19 serial-contains 'gotabwm: session exec WEB.ELF'
vgate_assert 19 serial-contains 'gotabwm: session exec GOEDIT.ELF'
vgate_assert 19 serial-contains 'gotabwm: session live n=3'
# No row dropped, no blob refused: every stored envelope went home.
vgate_assert 19 serial-count 'gotabwm: state restore id=' 3
vgate_assert 19 serial-absent 'gotabwm: session drop'
vgate_assert 19 serial-absent 'gotabwm: state drop'
vgate_assert 19 serial-absent 'state refused'
vgate_assert 19 serial-absent 'goedit: state stale'
vgate_assert 19 serial-absent 'state mismatch'
# Per-app exact state: the terminal reports the saved cwd + env + the
# replayed stream tail; the browser reports the blob's url; the editor
# reports the caret and live rings the typed 'zzz' produced.
vgate_assert 19 serial-contains 'goterm: state restored cwd=/M125G'
vgate_assert 19 serial-contains 'web: state restored url=/host/FORM.HTML'
vgate_assert 19 serial-contains 'goedit: state restored cur=17'
vgate_assert 19 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
m = re.search(r"goterm: state restored cwd=(\S+) env=(\d+) back=(\d+) "
              r"alt=(\d+) tail=(.*)$", ser, re.M)
if not m:
    sys.exit("missing goterm restore marker")
if m.group(1) != "/M125G":
    sys.exit("goterm cwd=%s" % m.group(1))
if int(m.group(3)) <= 0:
    sys.exit("goterm replayed an empty stream")
m2 = re.search(r"web: state restored url=(\S+) scroll=(\d+) zoom=(\d+) "
               r"forms=(\d+)/(\d+)$", ser, re.M)
if not m2:
    sys.exit("missing web restore marker")
if m2.group(3) != "100":
    sys.exit("web zoom=%s" % m2.group(3))
m3 = re.search(r"goedit: state restored cur=(\d+) sel=(\S+) undo=(\d+) "
               r"redo=(\d+) fh=(\d+) gh=(\d+)", ser)
if not m3:
    sys.exit("missing goedit restore marker")
if int(m3.group(3)) < 1:
    sys.exit("goedit restored with an empty undo ring")
print("restored: goterm cwd=%s env=%s back=%sB alt=%s tail=%r | "
      "web url=%s scroll=%s zoom=%s forms=%s/%s | "
      "goedit cur=%s sel=%s undo=%s" %
      (m.group(1), m.group(2), m.group(3), m.group(4), m.group(5),
       m2.group(1), m2.group(2), m2.group(3), m2.group(4), m2.group(5),
       m3.group(1), m3.group(2), m3.group(3)))
PY
vgate_assert 19 serial-contains 'rx-m125g-back-ok'
vgate_assert 19 serial-absent '[EXC] parking:'
vgate_assert 19 serial-absent 'exited status=139'


# ---------------------------------------------------------------------------
# Run 20 (M137a / #2771): the split is a tree. LIVE mode (no demo
# choreography): GOCALC+NOTE+GOEDIT. Two ctrl-shift-v presses reach three
# panes — the first splits the focused pane (depth-1 M62c), the second
# nests H inside it. ctrl+alt+arrows move pane focus by rect geometry;
# ctrl-shift-s takes the snapshot bundle; the sidecar SESSION.PANES is
# asserted on the share alongside LAYOUT.txt's three rects.

vgate_file script-20.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-20.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
exec NOTE.ELF
exec GOEDIT.ELF
EOF

vgate_file script3-20.txt <<'EOF'
wm
dui
echo rx-gotabwm-tree-ok
EOF

vgate_run 20 -- \
    --screen '$RUN_DIR/screen-20' \
    --script '$RUN_DIR/script-20.txt' \
    --script2 '$RUN_DIR/script2-20.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-v,ctrl-shift-v,ctrl-alt-right,ctrl-alt-left,ctrl-alt-down,ctrl-shift-s' \
    --input-chords-after 'gotabwm: rail n=3' \
    --script3 '$RUN_DIR/script3-20.txt' \
    --script3-after 'gotabwm: snapshot saved' \
    --script-expect 'rx-gotabwm-tree-ok' --timeout 300

vgate_assert 20 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 20 serial-contains 'gotabwm: registered'
vgate_assert 20 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 20 serial-contains 'gotabwm: rail n=3'
# Two presses, three panes: the focused pane split V, then nested H.
vgate_assert 20 serial-contains 'gotabwm: split v'
vgate_assert 20 serial-contains 'gotabwm: split h'
vgate_assert 20 serial-contains 'x=0 y=0 w=640 h=360'
vgate_assert 20 serial-contains 'x=0 y=360 w=640 h=360'
vgate_assert 20 serial-contains 'x=640 y=0 w=640 h=720'
# The directional chords moved pane focus by geometry.
vgate_assert 20 serial-contains 'gotabwm: tab focus id='
# The tree persisted beside the session, and the bundle carries it.
vgate_assert 20 serial-contains 'gotabwm: panes write n=3'
vgate_assert 20 serial-contains 'gotabwm: session write n=3'
vgate_assert 20 serial-contains 'gotabwm: snapshot saved'
vgate_assert 20 serial-contains 'rx-gotabwm-tree-ok'
vgate_assert 20 serial-absent 'gotabwm: panes bad'
vgate_assert 20 serial-absent '[EXC] parking:'
vgate_assert 20 serial-absent 'exited status=139'
vgate_assert 20 python <<'PY'
import os, re, sys
share = os.environ["VG_SHARE"]
# The sidecar is binary: PN\x01 then preorder tags. Magic + a v and an
# h tag is the whole structural assert a byte-level read needs.
blob = open(os.path.join(share, "SESSION.PANES"), "rb").read()
if blob[:3] != b"PN\x01":
    sys.exit("SESSION.PANES magic %r" % blob[:3])
if b"v" not in blob[3:] or b"h" not in blob[3:]:
    sys.exit("sidecar must carry both split kinds: %r" % blob)
# LAYOUT.txt: three panes, focused one marked, kinds recorded.
raw = open(os.path.join(share, "SELFTEST", "LAYOUT.txt"), "rb").read()
lines = raw.decode("utf-8").splitlines()
rows = [l for l in lines if l.startswith("tab=")]
if len(rows) != 3:
    sys.exit("layout rows=%d want 3" % len(rows))
if "split=v" not in raw.decode() or "split=h" not in raw.decode():
    sys.exit("layout must name both split kinds")
if "focus=1" not in raw.decode():
    sys.exit("no focused pane recorded")
print("panes sidecar %dB, layout rows: %s" % (len(blob), rows))
PY

# ---------------------------------------------------------------------------
# Run 21 (M137a / #2771): the snapshot restore round-trip. The bundle run
# 20 took carries SESSION.TABS + the panes sidecar; a fresh boot stages
# SNAPSHOT.RESTORE, rehydrates both files, and the seat decodes the tree
# (panes load n=3) and re-execs the rows. LAYOUT.txt then holds the same
# three pane rects — the layout survived the snapshot and the restore.

vgate_file script-21.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf open SNAPSHOT.RESTORE
vf write 0 1
wm
exec GOTABWM.ELF
EOF

vgate_file script3-21.txt <<'EOF'
wm
dui
echo rx-gotabwm-tree-restore-ok
EOF

vgate_run 21 -- \
    --screen '$RUN_DIR/screen-21' \
    --script '$RUN_DIR/script-21.txt' \
    --script3 '$RUN_DIR/script3-21.txt' \
    --script3-after 'gotabwm: snapshot restore' \
    --script-expect 'rx-gotabwm-tree-restore-ok' --timeout 300

vgate_assert 21 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 21 serial-contains 'gotabwm: snapshot restore'
vgate_assert 21 serial-contains 'gotabwm: session load n=3 mode=restore'
vgate_assert 21 serial-contains 'gotabwm: panes load n=3'
vgate_assert 21 serial-contains 'gotabwm: session reexec n=3'
vgate_assert 21 serial-contains 'gotabwm: session live n=3'
vgate_assert 21 serial-contains 'rx-gotabwm-tree-restore-ok'
vgate_assert 21 serial-absent 'gotabwm: panes bad'
vgate_assert 21 serial-absent '[EXC] parking:'
vgate_assert 21 serial-absent 'exited status=139'
vgate_assert 21 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
raw = open(os.path.join(share, "SELFTEST", "LAYOUT.txt"), "rb").read().decode("utf-8")
rows = [l for l in raw.splitlines() if l.startswith("tab=")]
if len(rows) != 3:
    sys.exit("restored layout rows=%d want 3" % len(rows))
# The same three rects run 20 computed must land verbatim.
for frag in ("x=0 y=0 w=640 h=360", "x=0 y=360 w=640 h=360",
             "x=640 y=0 w=640 h=720"):
    if frag not in raw:
        sys.exit("restored layout missing pane " + frag)
if "split=v" not in raw or "split=h" not in raw:
    sys.exit("restored layout lost the split kinds")
print("restored layout rows: %s" % rows)
PY

# ---------------------------------------------------------------------------
# Run 22 (M137c / #2773): spaces — named tab groups. LIVE mode: GOCALC+NOTE
# declare onto space "1". ctrl-alt-pagedown CREATES + lands on space "2"
# (the seat prints `space new name=2` and `space switch 1->2`, and hides
# space 1's windows through wmctl_set_state); the launcher execs GOEDIT
# onto space 2; the palette's palSpace row moves the focused space-1 tab
# over; ctrl-shift-e summons GOEMOJI.ELF — absent, so the seat's named
# exec refusal prints; ctrl-shift-s snapshots. On the share, SESSION.TABS
# records carry group names "1"/"2" and SESSION.PANES is the v2 frame
# holding both space names + the live index.

vgate_file script-22.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-22.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
exec NOTE.ELF
EOF

vgate_file script3-22.txt <<'EOF'
wm
dui
echo rx-gotabwm-spaces-ok
EOF

vgate_run 22 -- \
    --screen '$RUN_DIR/screen-22' \
    --script '$RUN_DIR/script-22.txt' \
    --script2 '$RUN_DIR/script2-22.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-alt-pagedown,ctrl-space,e,d,i,t,return,ctrl-alt-pageup,ctrl-shift-p,m,o,v,e,space,t,o,return,ctrl-shift-e,ctrl-shift-s' \
    --input-chords-after 'gotabwm: rail n=2' \
    --script3 '$RUN_DIR/script3-22.txt' \
    --script3-after 'gotabwm: snapshot saved' \
    --script-expect 'rx-gotabwm-spaces-ok' --timeout 300

vgate_assert 22 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 22 serial-contains 'gotabwm: registered'
# PageDown created + switched; the rail's marker names the live space.
vgate_assert 22 serial-contains 'gotabwm: space new name=2'
vgate_assert 22 serial-contains 'gotabwm: space switch 1->2'
vgate_assert 22 serial-contains 'gotabwm: space switch 2->1'
vgate_assert 22 serial-contains ' space=2'
vgate_assert 22 serial-contains ' space=1'
# GOEDIT landed on space 2; the palette move carried a tab across.
vgate_assert 22 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 22 serial-contains 'gotabwm: palette run move-to-space 2'
vgate_assert 22 serial-contains 'gotabwm: space move id='
# The summon chord: the absent app's named refusal, not silence.
vgate_assert 22 serial-contains 'gotabwm: refusal ENOENT exec GOEMOJI.ELF'
# Both spaces persist: group-named records + the v2 sidecar frame.
vgate_assert 22 serial-contains 'gotabwm: session write n=3'
vgate_assert 22 serial-contains 'gotabwm: session spaces n=2'
vgate_assert 22 serial-contains 'gotabwm: panes write n=0 spaces=2'
vgate_assert 22 serial-contains 'gotabwm: snapshot saved'
vgate_assert 22 serial-contains 'rx-gotabwm-spaces-ok'
vgate_assert 22 serial-absent 'gotabwm: panes bad'
vgate_assert 22 serial-absent 'gotabwm: session bad'
vgate_assert 22 serial-absent '[EXC] parking:'
vgate_assert 22 serial-absent 'exited status=139'
vgate_assert 22 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
raw = open(os.path.join(share, "SESSION.TABS"), "rb").read()
if not raw or raw[0] != 2:
    sys.exit("SESSION.TABS ver=%r" % (raw[:1]))
count = raw[2]
recs, off = [], 6
for i in range(count):
    title = raw[off:off+32].split(b"\0", 1)[0]
    group = raw[off+33:off+45].split(b"\0", 1)[0]
    recs.append((title, group))
    off += 69
groups = sorted(set(g for _, g in recs))
if groups != [b"1", b"2"]:
    sys.exit("record groups %r want {1,2}" % groups)
if len(recs) != 3:
    sys.exit("records=%d want 3" % len(recs))
blob = open(os.path.join(share, "SESSION.PANES"), "rb").read()
if blob[:5] != b"PN\x02\x02\x01":
    sys.exit("SESSION.PANES v2 header %r" % blob[:5])
if b"\x011\x00\x00" not in blob or b"\x012\x00\x00" not in blob:
    sys.exit("sidecar must carry both space names: %r" % blob)
print("records: %s | sidecar %dB" % (recs, len(blob)))
PY


# ---------------------------------------------------------------------------
# Run 23 (M137c / #2773): the snapshot restore. The bundle run 22 took
# carries the two-space session + the v2 sidecar; a fresh boot stages
# SNAPSHOT.RESTORE, rehydrates both files, and the seat decodes every
# space (`session spaces n=2 cur=1`), re-execs all three rows, and a
# switch chord round-trips the restored table.

vgate_file script-23.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf open SNAPSHOT.RESTORE
vf write 0 1
wm
exec GOTABWM.ELF
EOF

vgate_file script3-23.txt <<'EOF'
wm
dui
echo rx-gotabwm-spaces-restore-ok
EOF

vgate_run 23 -- \
    --screen '$RUN_DIR/screen-23' \
    --script '$RUN_DIR/script-23.txt' \
    --input-chords 'ctrl-alt-pagedown,ctrl-alt-pageup' \
    --input-chords-after 'gotabwm: session live n=3' \
    --script3 '$RUN_DIR/script3-23.txt' \
    --script3-after 'gotabwm: space switch 2->1' \
    --script-expect 'rx-gotabwm-spaces-restore-ok' --timeout 300

vgate_assert 23 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 23 serial-contains 'gotabwm: snapshot restore'
vgate_assert 23 serial-contains 'gotabwm: session load n=3 mode=restore'
vgate_assert 23 serial-contains 'gotabwm: session spaces n=2 cur=1'
vgate_assert 23 serial-contains 'gotabwm: panes load n=0 spaces=2'
vgate_assert 23 serial-contains 'gotabwm: session reexec n=3'
vgate_assert 23 serial-contains 'gotabwm: session live n=3'
vgate_assert 23 serial-contains 'gotabwm: rail n=3'
vgate_assert 23 serial-contains ' space=1'
# The restored table still switches: 1->2 lands on the empty space, 2->1
# returns to the three restored rows.
vgate_assert 23 serial-contains 'gotabwm: space switch 1->2'
vgate_assert 23 serial-contains 'gotabwm: space switch 2->1'
vgate_assert 23 serial-contains 'rx-gotabwm-spaces-restore-ok'
vgate_assert 23 serial-absent 'gotabwm: panes bad'
vgate_assert 23 serial-absent 'gotabwm: session bad'
vgate_assert 23 serial-absent '[EXC] parking:'
vgate_assert 23 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 24 (M151a / #2912): pane posture — zoom, rail drag into a pane, MRU
# focus restore. LIVE mode (the DEMO trigger is removed), GOCALC+NOTE like
# run 01's pair.
#
# Chord/pointer choreography (each stage waits on the previous leg's own
# marker):
#   ctrl-shift-v            split the focused pane (last declarer takes the
#                           left leaf, the other tab the right)
#   palette "Zoom pane"     the focused leaf goes full-viewport, the sibling
#                           parks hidden — the script3 `dui` dump lands
#                           INSIDE the zoom window (it fires on `zoom on`
#                           and the ~4 s of restore-palette keystrokes
#                           hold the posture open), so the kernel registry
#                           is the scanout probe: zoomed rect 0,0,1280,720
#                           and the parked user window visible=0.
#   palette "Restore panes" the tree re-lands (`zoom off`)
#   two rail drags onto the right pane — cell1's tab drops (swap), then
#                           cell0's (now the left leaf after the first
#                           swap) drops back: exactly two `pane drop`
#                           markers, ending in the original placement
#   click cell1's body      re-focuses it (feeds the MRU ring)
#   click cell1's close-x   a focused close: `focus restore id= why=close`
#                           names the most recent survivor
# The run ends on the seat's `focus restore` marker — the last leg's own
# evidence, so no script-supplied tail can outrun it.
vgate_file script-24.txt <<'EOF2'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
wm
exec GOTABWM.ELF
EOF2

vgate_file script2-24.txt <<'EOF2'
dui focus 0
exec GOCALC.ELF
exec NOTE.ELF
EOF2

# script3 is the mid-zoom probe, not the tail: `dui` lands while the
# palette's restore strokes are still draining.
vgate_file script3-24.txt <<'EOF2'
dui
EOF2

vgate_run 24 -- \
    --screen '$RUN_DIR/screen-24' \
    --via-virtio \
    --script '$RUN_DIR/script-24.txt' \
    --script2 '$RUN_DIR/script2-24.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-v,ctrl-shift-p,z,o,o,m,space,p,a,n,e,return,ctrl-shift-p,r,e,s,t,o,r,e,space,p,a,n,e,s,return' \
    --input-chords-after 'gotabwm: rail n=2' \
    --script3 '$RUN_DIR/script3-24.txt' \
    --script3-after 'gotabwm: zoom on id=' \
    --pointer-virtio '960,8,d;1000,400,u;100,8,d;1000,400,u;700,8,c;1270,8,c' \
    --pointer-virtio-after 'gotabwm: zoom off' \
    --script-expect 'gotabwm: focus restore' --timeout 300

vgate_assert 24 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 24 serial-contains 'gotabwm: registered'
vgate_assert 24 serial-contains 'gotabwm: mode live'
vgate_assert 24 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 24 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert 24 serial-contains 'gotabwm: rail n=2'
vgate_assert 24 serial-contains 'gotabwm: split v'
# The palette rows dispatched and the posture markers printed.
vgate_assert 24 serial-contains 'gotabwm: palette run zoom-pane'
vgate_assert 24 serial-contains 'gotabwm: zoom on id='
vgate_assert 24 serial-contains 'gotabwm: palette run restore-panes'
vgate_assert 24 serial-contains 'gotabwm: zoom off'
# The drop and the MRU focus restore.
vgate_assert 24 serial-contains 'gotabwm: pane drop id='
vgate_assert 24 serial-contains ' leaf='
vgate_assert 24 serial-contains 'gotabwm: tab close id='
vgate_assert 24 serial-contains 'gotabwm: focus restore id='
vgate_assert 24 serial-contains ' why=close'
vgate_assert 24 serial-absent 'gotabwm: panes bad'
vgate_assert 24 serial-absent '[EXC] parking:'
vgate_assert 24 serial-absent 'exited status=139'
# Zoom ordering + the zoomed LAYOUT dump: the layout lines between
# `zoom on` and `zoom off` show the zoomed tab at the full viewport with
# focus=1 (the dump names the applied rect, not the tree's).
vgate_assert 24 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
zi = ser.find("gotabwm: zoom on id=")
zo = ser.find("gotabwm: zoom off")
pd = ser.find("gotabwm: pane drop")
fr = ser.find("gotabwm: focus restore")
if not (0 <= zi < zo < pd < fr):
    sys.exit("leg order wrong: zoom_on=%d zoom_off=%d drop=%d restore=%d"
             % (zi, zo, pd, fr))
m = re.search(r"gotabwm: zoom on id=(\d+)", ser)
zid = m.group(1)
lay = re.search(r"gotabwm: layout tab=%s .*w=1280 h=720.*focus=1" % zid,
                ser[zi:zo])
if not lay:
    sys.exit("no zoomed full-viewport layout line for tab %s" % zid)
# The sibling's own pane rect still dumps (parked, not resized).
other = re.findall(r"gotabwm: layout tab=(\d+) .*w=640 h=720", ser[zi:zo])
if not other or zid in other:
    sys.exit("no parked sibling at its pane rect: %s" % other)
print("zoom on id=%s: layout %s ; parked %s" % (zid, lay.group(0), other))
PY
# The scanout probe: script3's `dui` ran inside the zoom window, so the
# kernel registry shows the zoomed user window at the full scanout and
# the parked sibling hidden — between `zoom on` and `zoom off` in serial.
vgate_assert 24 python <<'PY'
import os, re, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
zi = next(i for i, l in enumerate(lines) if "gotabwm: zoom on id=" in l)
zo = next(i for i, l in enumerate(lines) if "gotabwm: zoom off" in l)
seg = lines[zi:zo]
rows = [l for l in seg if l.startswith("dui[") and " user " in l]
if not any("rect=0,0,1280,720" in r and "visible=1" in r for r in rows):
    sys.exit("no user window at the full scanout inside the zoom: %s" % rows)
if not any("visible=0" in r for r in rows):
    sys.exit("no parked (hidden) user window inside the zoom: %s" % rows)
print("dui probe inside zoom: %s" % rows)
PY
# The drop recorded the leaf and the close's restore names the survivor:
# parse the two client ids, the closed id, and the restored id — the
# survivor must be the OTHER live window (with two tabs it is also the
# rail neighbour; the MRU-vs-neighbour discrimination is the class-A
# test's job).
vgate_assert 24 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
ids = set()
for pat in (r"gocalc: open id=(\d+)", r"note: open id=(\d+)"):
    m = re.search(pat, ser)
    if not m:
        sys.exit("missing app open marker %s" % pat)
    ids.add(int(m.group(1)))
dm = re.findall(r"gotabwm: pane drop id=(\d+) leaf=(\d+)", ser)
if not dm:
    sys.exit("no pane drop marker")
if any(int(i) not in ids for i, _ in dm):
    sys.exit("pane drop named a non-client id: %s" % dm)
cm = re.search(r"gotabwm: tab close id=(\d+)", ser)
fm = re.search(r"gotabwm: focus restore id=(\d+) why=close", ser)
if not cm or not fm:
    sys.exit("missing close/restore markers")
closed, restored = int(cm.group(1)), int(fm.group(1))
if closed not in ids or restored not in ids or closed == restored:
    sys.exit("close=%d restore=%d ids=%s" % (closed, restored, ids))
print("drops=%s close=%d focus restore -> %d" % (dm, closed, restored))
PY
# The drop persisted through the write-through hook: a session write
# follows it, and the tree is still live (panes sidecar re-written).
vgate_assert 24 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
i_drop = ser.find("gotabwm: pane drop")
i_write = ser.find("gotabwm: session write", i_drop)
if i_drop < 0 or i_write < 0:
    sys.exit("drop=%d write=%d — the drop must persist" % (i_drop, i_write))
print("pane drop at %d persisted by write at %d" % (i_drop, i_write))
PY

# ---------------------------------------------------------------------------
# Run 25 (M151b / #2913): the visible space switcher — rail pills and the
# palette's "Switch to space N" rows. LIVE mode (the DEMO trigger is
# removed), GOCALC+NOTE like run 01's pair.
#
# One input-chords burst and one pointer burst are all the harness offers,
# so the legs run palette-first and the third client is moved, not exec'd
# (a launcher "edit" pick is not deterministic on this share — run 22's
# GOEDIT leg is the casualty). The chord stream creates spaces 2 and 3
# (each PageDown creates + lands), pages back to space 1, moves the
# focused tab to space 3 through the M137c move row, then runs "Switch to
# space 3". The pointer leg waits on the palette's own switch marker, so
# the click lands on space 3's painted rail: pill "1" is the leftmost of
# the right-aligned strip (8px bitmap metrics on this share — no
# FONTS.TXT — so pills are 16 px wide ending 4 px short of the edge:
# [1220,1236)x[3,19)); the click at 1228,11 prints `space pick 1` then
# `space switch 3->1`.
#
# script3 rides the pick marker; its rx echo keys the screenshot — many
# ticks sit between the last switch and the grab (the run-05 idiom), so
# the frame is the settled space-1 rail with pill "1" on the Accent plate.
vgate_file script-25.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-25.txt <<'EOF'
dui focus 0
exec GOCALC.ELF
exec NOTE.ELF
EOF

vgate_file script3-25.txt <<'EOF'
wm
dui
echo rx-gotabwm-space-switcher-ok
EOF

vgate_run 25 -- \
    --screen '$RUN_DIR/screen-25' \
    --screenshot-after 'rx-gotabwm-space-switcher-ok' \
    --script '$RUN_DIR/script-25.txt' \
    --script2 '$RUN_DIR/script2-25.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-alt-pagedown,ctrl-alt-pagedown,ctrl-alt-pageup,ctrl-alt-pageup,ctrl-shift-p,m,o,v,e,space,3,return,ctrl-shift-p,s,w,i,t,c,h,space,t,o,space,3,return' \
    --input-chords-after 'gotabwm: rail n=2' \
    --pointer-virtio '1228,11,c' \
    --pointer-virtio-after 'gotabwm: space switch 1->3' \
    --script3 '$RUN_DIR/script3-25.txt' \
    --script3-after 'gotabwm: space pick 1' \
    --script-expect 'rx-gotabwm-space-switcher-ok' --timeout 300

vgate_assert 25 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 25 serial-contains 'gotabwm: registered'
vgate_assert 25 serial-contains 'gotabwm: mode live'
vgate_assert 25 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 25 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert 25 serial-contains 'gotabwm: rail n=2'
# The chord's two PageDowns created and landed on each new space.
vgate_assert 25 serial-contains 'gotabwm: space new name=2'
vgate_assert 25 serial-contains 'gotabwm: space new name=3'
vgate_assert 25 serial-contains 'gotabwm: space switch 1->2'
vgate_assert 25 serial-contains 'gotabwm: space switch 2->3'
vgate_assert 25 serial-contains 'gotabwm: space switch 2->1'
# The move row parked a tab on space 3; the switch row carried the desktop.
vgate_assert 25 serial-contains 'gotabwm: palette run move-to-space 3'
vgate_assert 25 serial-contains 'gotabwm: space move id='
vgate_assert 25 serial-contains 'gotabwm: palette run switch-to-space 3'
vgate_assert 25 serial-contains 'gotabwm: space switch 1->3'
# The rail marker names the live space on both ends of the run.
vgate_assert 25 serial-contains ' space=3'
vgate_assert 25 serial-contains ' space=1'
# The pill click: the pick marker, then the switch back to space 1.
vgate_assert 25 serial-contains 'gotabwm: space pick 1'
vgate_assert 25 serial-contains 'gotabwm: space switch 3->1'
vgate_assert 25 serial-contains 'gotabwm: session spaces n=3'
vgate_assert 25 serial-contains 'rx-gotabwm-space-switcher-ok'
vgate_assert 25 serial-absent 'gotabwm: panes bad'
vgate_assert 25 serial-absent 'gotabwm: session bad'
vgate_assert 25 serial-absent '[EXC] parking:'
vgate_assert 25 serial-absent 'exited status=139'
# Ordering: the pick gesture precedes the switch it ran, and both precede
# the rx echo that keys the capture.
vgate_assert 25 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
i_pick = ser.find("gotabwm: space pick 1")
i_sw = ser.find("gotabwm: space switch 3->1")
i_rx = ser.find("rx-gotabwm-space-switcher-ok")
if not (0 <= i_pick < i_sw < i_rx):
    sys.exit("leg order wrong: pick=%d switch=%d rx=%d" % (i_pick, i_sw, i_rx))
print("space pick 1 -> space switch 3->1 -> rx: ordered")
PY
# The `dui` dump after the pick shows space 3's window hidden — the pill's
# switch ran the real wmctl_set_state path, not just a marker. Scoped to
# the full-viewport tab rows (the seat's own small sink/chrome windows are
# user-kind too): Calc shown on space 1, the moved Note parked on space 3.
vgate_assert 25 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
i_pick = ser.find("gotabwm: space pick 1")
rows = [l for l in ser[i_pick:].splitlines()
        if l.startswith("dui[") and " user " in l
        and "rect=0,0,1280,720" in l]
hidden = [l for l in rows if "visible=0" in l]
shown = [l for l in rows if "visible=1" in l]
if len(hidden) != 1 or len(shown) != 1:
    sys.exit("post-pick dui tab rows: %s" % rows)
print("post-pick dui: 1 parked tab hidden, 1 shown")
PY
# The scanout probe: three pills at the rail's right edge on the settled
# post-switch frame — the live space "1" on the Accent plate (blue-
# dominant, the capture's channel shift), the dormant pair recessed in
# Bg with the inter-pill gap showing the cell behind. Counts over each
# rect, not point samples, so the name glyphs can't poison the read.
vgate_assert 25 snapshot 'screen-25-after*' <<'PY'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, "rb").read()
if d[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("not a PNG")
pos = 8; idat = b""; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack(">I4s", d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b"IHDR":
        w, h, bd, ct = struct.unpack(">IIBB", data[:10])
    elif typ == b"IDAT":
        idat += data
    pos += 12 + ln
raw = zlib.decompress(idat)
bpp = 4 if ct == 6 else 3
stride = w * bpp
out = bytearray(); prev = bytearray(stride); i = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp]
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line
def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]
def near(rgb, token, tol=4):
    return all(abs(a - b) <= tol for a, b in zip(rgb, token))
def blue(rgb):
    r, g, b = rgb
    return b > 150 and b > r + 40 and b > g + 40
BG = (0x18, 0x20, 0x26)
scale = w / 1280.0
def rect(x0, x1, y0, y1):
    return [(x, y) for y in range(int(y0*scale), int(y1*scale))
            for x in range(int(x0*scale), int(x1*scale))]
# Live pill "1" [1220,1236)x[3,19): mostly Accent plate (the bitmap '1'
# glyph costs a few px), plus at least two ChromeBg-dark glyph strokes.
r1 = rect(1221, 1235, 4, 18)
if sum(1 for p in r1 if blue(px(*p))) < 150:
    sys.exit("live pill shows %d accent px — no Accent plate" %
             sum(1 for p in r1 if blue(px(*p))))
if sum(1 for p in r1 if max(px(*p)) < 0x60) < 2:
    sys.exit("live pill shows no name glyph")
# Dormant pills "2" [1240,1256) and "3" [1260,1276): recessed plates over
# the Selection cell. The capture path crushes the dark channels (Bg
# 0x182026 reads ~(8,9,37) — measured on this run's evidence file), so the
# plate is asserted as a dark non-cell family and the name's muted-ink
# glyph strokes prove a pill — not a bare gap — sits there.
def darkish(rgb):
    return rgb[2] < 80 and rgb[0] < 40 and rgb[1] < 45
def muted_ink(rgb):
    r, g, b = rgb
    return r > 100 and g > 110 and b > 140
for tag, (x0, x1) in (("2", (1241, 1255)), ("3", (1261, 1275))):
    rr = rect(x0, x1, 4, 18)
    if sum(1 for p in rr if darkish(px(*p))) < 100:
        sys.exit("dormant pill %s shows no recessed plate" % tag)
    if sum(1 for p in rr if muted_ink(px(*p))) < 2:
        sys.exit("dormant pill %s shows no name glyph" % tag)
# The 4 px inter-pill gap shows the cell behind (Selection — space 1's
# focused tab fills the rail), not pill fill: three plates, not a bar.
gap = px(int(1238 * scale), int(11 * scale))
if darkish(gap) or blue(gap):
    sys.exit("inter-pill gap %r looks like pill fill" % (gap,))
print("pill strip: live accent plate + glyph, dormant recessed+glyph, gap shows cell")
PY
vgate_run 26 -- \
    --screen '$RUN_DIR/screen-24' \
    --via-virtio \
    --script '$RUN_DIR/script-24.txt' \
    --script2 '$RUN_DIR/script2-24.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-24.txt' \
    --script3-after 'gopaint: ready' \
    --input-chords 'h,i,return,ctrl-shift-s' \
    --input-chords-after 'goassist: present' \
    --script-expect 'gotabwm: snapshot saved' --timeout 420

vgate_assert 24 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 24 serial-contains 'gotabwm: registered'
vgate_assert 24 serial-contains 'exec: loaded GOPAINT.ELF'
vgate_assert 24 serial-contains 'gopaint: loaded /host/PAINT.QOI'
vgate_assert 24 serial-contains 'gopaint: ready'
vgate_assert 24 serial-contains 'exec: loaded GOASSIST.ELF'
vgate_assert 24 serial-contains 'goassist: declare accepted'
vgate_assert 24 serial-contains 'goassist: present'
vgate_assert 24 serial-contains 'goassist: committed conv='
vgate_assert 24 serial-count 'gotabwm: state ask id=' 2
vgate_assert 24 serial-count 'gotabwm: state save id=' 2
vgate_assert 24 serial-contains 'gotabwm: snapshot saved'
vgate_assert 24 serial-absent 'goassist: state refused'
vgate_assert 24 serial-absent 'gopaint: state stale'
vgate_assert 24 serial-absent 'gotabwm: state drop'
vgate_assert 24 serial-absent '[EXC] parking:'
vgate_assert 24 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 25 (M151c): pair A restore — the seat re-execs both recorded bins
# (both declare their ELF names, so no alias is needed) and each app's own
# marker reports the blob back: Assist's conv name/turns, Paint's file.

vgate_file script-25.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-25.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-25.txt <<'EOF'
wm
dui
echo rx-audit-a-rest-ok
EOF

vgate_run 27 -- \
    --screen '$RUN_DIR/screen-25' \
    --via-virtio \
    --script '$RUN_DIR/script-25.txt' \
    --script2 '$RUN_DIR/script2-25.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-25.txt' \
    --script3-after 'gotabwm: session live n=2' --script3-delay 8 \
    --script-expect 'rx-audit-a-rest-ok' --timeout 300

vgate_assert 25 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 25 serial-contains 'gotabwm: session load n=2 mode=restore'
vgate_assert 25 serial-contains 'gotabwm: session reexec n=2'
vgate_assert 25 serial-contains 'gotabwm: session exec GOPAINT.ELF'
vgate_assert 25 serial-contains 'gotabwm: session exec GOASSIST.ELF'
vgate_assert 25 serial-contains 'gotabwm: session live n=2'
vgate_assert 25 serial-count 'gotabwm: state restore id=' 2
vgate_assert 25 serial-contains 'goassist: state restored conv='
vgate_assert 25 serial-contains ' turns='
vgate_assert 25 serial-contains 'gopaint: state restored file=/host/PAINT.QOI'
vgate_assert 25 serial-contains 'rx-audit-a-rest-ok'
vgate_assert 25 serial-absent 'goassist: state refused'
vgate_assert 25 serial-absent 'gopaint: state stale'
vgate_assert 25 serial-absent 'gotabwm: state drop'
vgate_assert 25 serial-absent '[EXC] parking:'
vgate_assert 25 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 26 (M151c): pair B save — GOREADER + GOSHEET. Reader's argv path IS
# its state (on a bare re-exec it can only reopen through the blob); the
# sheet — last in, focused — takes the run-06 cell edit (A1=5, A2==a1+a1).

vgate_file script-26.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-26.txt <<'EOF'
dui focus 0
exec GOREADER.ELF /host/AUDIT.PDF
EOF

vgate_file script3-26.txt <<'EOF'
exec GOSHEET.ELF
EOF

vgate_run 28 -- \
    --screen '$RUN_DIR/screen-26' \
    --via-virtio \
    --script '$RUN_DIR/script-26.txt' \
    --script2 '$RUN_DIR/script2-26.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-26.txt' \
    --script3-after 'goreader: ready' \
    --input-chords '5,return,down,=,a,1,+,a,1,return,ctrl-shift-s' \
    --input-chords-after 'gosheet: present' \
    --script-expect 'gotabwm: snapshot saved' --timeout 420

vgate_assert 26 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 26 serial-contains 'gotabwm: registered'
vgate_assert 26 serial-contains 'exec: loaded GOREADER.ELF'
vgate_assert 26 serial-contains 'goreader: loaded AUDIT.PDF pages=3'
vgate_assert 26 serial-contains 'goreader: ready'
vgate_assert 26 serial-contains 'exec: loaded GOSHEET.ELF'
vgate_assert 26 serial-contains 'gosheet: declare accepted'
vgate_assert 26 serial-contains 'gosheet: present'
vgate_assert 26 serial-contains "gosheet: set A1 := '5' -> 5"
vgate_assert 26 serial-contains "gosheet: set A2 := '=a1+a1' -> 10"
vgate_assert 26 serial-contains 'goreader: state saved n='
vgate_assert 26 serial-contains 'gosheet: state saved n='
vgate_assert 26 serial-count 'gotabwm: state ask id=' 2
vgate_assert 26 serial-count 'gotabwm: state save id=' 2
vgate_assert 26 serial-contains 'gotabwm: snapshot saved'
vgate_assert 26 serial-absent 'gosheet: state stale'
vgate_assert 26 serial-absent 'gosheet: state oversize'
vgate_assert 26 serial-absent 'goreader: refuse'
vgate_assert 26 serial-absent 'gotabwm: state drop'
vgate_assert 26 serial-absent '[EXC] parking:'
vgate_assert 26 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 27 (M151c): pair B restore — the sheet row re-execs its ELF-named
# bin; the reader row re-execs the staged "Reader" alias (its declared
# title has no guessBin row). Reader gets NO argv on re-exec — it can only
# reopen AUDIT.PDF because the blob carried the path, which is exactly the
# round-trip this audit exists to observe.

vgate_file script-27.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-27.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-27.txt <<'EOF'
wm
dui
echo rx-audit-b-rest-ok
EOF

vgate_run 29 -- \
    --screen '$RUN_DIR/screen-27' \
    --via-virtio \
    --script '$RUN_DIR/script-27.txt' \
    --script2 '$RUN_DIR/script2-27.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-27.txt' \
    --script3-after 'gotabwm: session live n=2' --script3-delay 8 \
    --script-expect 'rx-audit-b-rest-ok' --timeout 300

vgate_assert 27 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 27 serial-contains 'gotabwm: session load n=2 mode=restore'
vgate_assert 27 serial-contains 'gotabwm: session reexec n=2'
vgate_assert 27 serial-contains 'gotabwm: session exec GOSHEET.ELF'
vgate_assert 27 serial-contains 'gotabwm: session exec Reader'
vgate_assert 27 serial-contains 'gotabwm: session live n=2'
vgate_assert 27 serial-count 'gotabwm: state restore id=' 2
vgate_assert 27 serial-contains 'goreader: loaded AUDIT.PDF'
vgate_assert 27 serial-contains 'goreader: restored page='
vgate_assert 27 serial-contains 'gosheet: state restored cells=2'
vgate_assert 27 serial-contains 'rx-audit-b-rest-ok'
vgate_assert 27 serial-absent 'gosheet: state stale'
vgate_assert 27 serial-absent 'goreader: state stale'
vgate_assert 27 serial-absent 'gotabwm: state drop'
vgate_assert 27 serial-absent '[EXC] parking:'
vgate_assert 27 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 28 (M151c): pair C save — GOMINE + GOCLOCK. Mines' argv sizes the
# 16x16 intermediate board directly ('1 1': seed=1, size=1 — no '2' key
# needed); the clock — last in, focused — takes the run-04 alarm sequence.

vgate_file script-28.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-28.txt <<'EOF'
dui focus 0
exec GOMINE.ELF 1 1
EOF

vgate_file script3-28.txt <<'EOF'
exec GOCLOCK.ELF
EOF

vgate_run 30 -- \
    --screen '$RUN_DIR/screen-28' \
    --via-virtio \
    --script '$RUN_DIR/script-28.txt' \
    --script2 '$RUN_DIR/script2-28.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-28.txt' \
    --script3-after 'gomine: present' \
    --input-chords 'right,right,right,2,3,5,9,return,ctrl-shift-s' \
    --input-chords-after 'goclock: painted epoch=' \
    --script-expect 'gotabwm: snapshot saved' --timeout 420

vgate_assert 28 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 28 serial-contains 'gotabwm: registered'
vgate_assert 28 serial-contains 'exec: loaded GOMINE.ELF'
vgate_assert 28 serial-contains 'gomine: seed 1 size=intermediate'
vgate_assert 28 serial-contains 'gomine: present'
vgate_assert 28 serial-contains 'exec: loaded GOCLOCK.ELF'
vgate_assert 28 serial-contains 'goclock: declare accepted'
vgate_assert 28 serial-contains 'goclock: tab alarm'
vgate_assert 28 serial-contains 'goclock: alarm armed 23:59'
vgate_assert 28 serial-contains 'goclock: alarm saved'
vgate_assert 28 serial-contains 'goclock: state posted'
vgate_assert 28 serial-contains 'gomine: state saved len='
vgate_assert 28 serial-count 'gotabwm: state ask id=' 2
vgate_assert 28 serial-count 'gotabwm: state save id=' 2
vgate_assert 28 serial-contains 'gotabwm: snapshot saved'
vgate_assert 28 serial-absent 'goclock: alarm save failed'
vgate_assert 28 serial-absent 'gomine: boom'
vgate_assert 28 serial-absent 'gotabwm: state drop'
vgate_assert 28 serial-absent '[EXC] parking:'
vgate_assert 28 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 29 (M151c): pair C restore — `goclock: state restored` prints only
# when the seat actually served the blob (the .ALARM file is a second,
# independent carrier — the marker names the wire), and the armed record
# reports the 23:59 deadline back. Mines' row re-execs the "Mines" alias
# (no guessBin row for the title) and reports the intermediate board.

vgate_file script-29.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-29.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-29.txt <<'EOF'
wm
dui
echo rx-audit-c-rest-ok
EOF

vgate_run 31 -- \
    --screen '$RUN_DIR/screen-29' \
    --via-virtio \
    --script '$RUN_DIR/script-29.txt' \
    --script2 '$RUN_DIR/script2-29.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-29.txt' \
    --script3-after 'gotabwm: session live n=2' --script3-delay 8 \
    --script-expect 'rx-audit-c-rest-ok' --timeout 300

vgate_assert 29 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 29 serial-contains 'gotabwm: session load n=2 mode=restore'
vgate_assert 29 serial-contains 'gotabwm: session reexec n=2'
vgate_assert 29 serial-contains 'gotabwm: session exec Mines'
vgate_assert 29 serial-contains 'gotabwm: session exec GOCLOCK.ELF'
vgate_assert 29 serial-contains 'gotabwm: session live n=2'
vgate_assert 29 serial-count 'gotabwm: state restore id=' 2
vgate_assert 29 serial-contains 'goclock: state restored'
vgate_assert 29 serial-contains 'goclock: alarm restored 23:59'
vgate_assert 29 serial-contains 'gomine: state restored size=intermediate'
vgate_assert 29 serial-contains 'rx-audit-c-rest-ok'
vgate_assert 29 serial-absent 'gomine: state stale'
vgate_assert 29 serial-absent 'gotabwm: state drop'
vgate_assert 29 serial-absent '[EXC] parking:'
vgate_assert 29 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 30 (M151c): pair D save — GOSOL + GOEMOJI. Solitaire's argv deals
# seed=1 draw=3; the picker — last in, focused — takes the 'fire' query.
# GOEMOJI is this audit's second named finding: its SaveState/RestoreState
# closures are wired, but the appkit event loop never calls PollStateAsk —
# the seat's ask posts and is never answered, so no blob is stored. The
# assert set therefore expects exactly ONE save (Solitaire's), and the
# audit row names the gap for M152c (#2917).

vgate_file script-30.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-30.txt <<'EOF'
dui focus 0
exec GOSOL.ELF --seed=1 --draw=3
EOF

vgate_file script3-30.txt <<'EOF'
exec GOEMOJI.ELF
EOF

vgate_run 32 -- \
    --screen '$RUN_DIR/screen-30' \
    --via-virtio \
    --script '$RUN_DIR/script-30.txt' \
    --script2 '$RUN_DIR/script2-30.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-30.txt' \
    --script3-after 'gosol: ready' \
    --input-chords 'f,i,r,e,ctrl-shift-s' \
    --input-chords-after 'goemoji: present' \
    --script-expect 'gotabwm: snapshot saved' --timeout 420

vgate_assert 30 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 30 serial-contains 'gotabwm: registered'
vgate_assert 30 serial-contains 'exec: loaded GOSOL.ELF'
vgate_assert 30 serial-contains 'gosol: deal seed=1 draw=3'
vgate_assert 30 serial-contains 'gosol: ready'
vgate_assert 30 serial-contains 'exec: loaded GOEMOJI.ELF'
vgate_assert 30 serial-contains 'goemoji: declare accepted'
vgate_assert 30 serial-contains 'goemoji: fonts manifest=ok'
vgate_assert 30 serial-contains 'goemoji: present'
vgate_assert 30 serial-contains 'goemoji: filter q=fire n=1'
vgate_assert 30 serial-contains 'gosol: state save len='
vgate_assert 30 serial-count 'gotabwm: state ask id=' 2
vgate_assert 30 serial-count 'gotabwm: state save id=' 1
vgate_assert 30 serial-contains 'gotabwm: snapshot saved'
vgate_assert 30 serial-absent 'gosol: drop bad'
vgate_assert 30 serial-absent 'gotabwm: state drop'
vgate_assert 30 serial-absent '[EXC] parking:'
vgate_assert 30 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 31 (M151c): pair D restore — the Solitaire row re-execs the
# "Solitaire" alias and reports its restored move count without a re-deal
# (`gosol: deal seed=` is absent: the table came from the blob). GOEMOJI's
# row still re-execs and adopts — the tab comes back — but the seat never
# stored a blob for it, so no `state restore` line names its window and no
# 'fire' filter reprints: the wire-level evidence of the finding.

vgate_file script-31.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-31.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-31.txt <<'EOF'
wm
dui
echo rx-audit-d-rest-ok
EOF

vgate_run 33 -- \
    --screen '$RUN_DIR/screen-31' \
    --via-virtio \
    --script '$RUN_DIR/script-31.txt' \
    --script2 '$RUN_DIR/script2-31.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-31.txt' \
    --script3-after 'gotabwm: session live n=2' --script3-delay 8 \
    --script-expect 'rx-audit-d-rest-ok' --timeout 300

vgate_assert 31 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 31 serial-contains 'gotabwm: session load n=2 mode=restore'
vgate_assert 31 serial-contains 'gotabwm: session reexec n=2'
vgate_assert 31 serial-contains 'gotabwm: session exec Solitaire'
vgate_assert 31 serial-contains 'gotabwm: session exec Emoji'
vgate_assert 31 serial-contains 'gotabwm: session live n=2'
vgate_assert 31 serial-count 'gotabwm: state restore id=' 1
vgate_assert 31 serial-contains 'gosol: restored moves='
vgate_assert 31 serial-contains 'goemoji: open id='
vgate_assert 31 serial-absent 'goemoji: filter q=fire'
vgate_assert 31 serial-contains 'rx-audit-d-rest-ok'
vgate_assert 31 serial-absent 'gosol: deal seed='
vgate_assert 31 serial-absent 'gotabwm: state drop'
vgate_assert 31 serial-absent '[EXC] parking:'
vgate_assert 31 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 32 (M151c): pair E save — GOVAULT + GOIRC. Vault — first in — just
# sits bound at its create face: no hooks exist to answer the ask (the
# card's named gap; M156c #2933 owns the app). IRC — last in, focused —
# answers the consent gate yes ('tab,return') and dials plain to a host
# that can never answer without a net device: `goirc: closed` is the
# offline end-state, not a crash.

vgate_file script-32.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
vf rm GOVAULT/VAULT.BIN
wm
exec GOTABWM.ELF
EOF

vgate_file script2-32.txt <<'EOF'
dui focus 0
exec GOVAULT.ELF
EOF

vgate_file script3-32.txt <<'EOF'
exec GOIRC.ELF --ui --host=10.0.0.2 --nick=gate --join '#goirc'
EOF

vgate_run 34 -- \
    --screen '$RUN_DIR/screen-32' \
    --via-virtio \
    --script '$RUN_DIR/script-32.txt' \
    --script2 '$RUN_DIR/script2-32.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-32.txt' \
    --script3-after 'govault: new vault' \
    --input-chords 'tab,return,pageup,pageup,ctrl-shift-s' \
    --input-chords-after 'goirc: consent ask' \
    --script-expect 'gotabwm: snapshot saved' --timeout 420

vgate_assert 32 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 32 serial-contains 'gotabwm: registered'
vgate_assert 32 serial-contains 'exec: loaded GOVAULT.ELF'
vgate_assert 32 serial-contains 'govault: declare accepted'
vgate_assert 32 serial-contains 'govault: new vault'
vgate_assert 32 serial-contains 'exec: loaded GOIRC.ELF'
vgate_assert 32 serial-contains 'goirc: declare accepted'
vgate_assert 32 serial-contains 'goirc: consent ask'
vgate_assert 32 serial-contains 'goirc: consent yes'
vgate_assert 32 serial-contains 'goirc: state saved'
vgate_assert 32 serial-contains 'goirc: dial 10.0.0.2 6667 plain'
vgate_assert 32 serial-count 'gotabwm: state ask id=' 2
vgate_assert 32 serial-count 'gotabwm: state save id=' 1
vgate_assert 32 serial-contains 'gotabwm: snapshot saved'
vgate_assert 32 serial-absent 'goirc: refuse plaintext'
vgate_assert 32 serial-absent 'goirc: state refused'
vgate_assert 32 serial-absent 'gotabwm: state drop'
vgate_assert 32 serial-absent '[EXC] parking:'
vgate_assert 32 serial-absent 'exited status=139'

# ---------------------------------------------------------------------------
# Run 33 (M151c): pair E restore + the report. GOIRC's blob carries the
# consent answer, so the restored tab re-dials plain WITHOUT a second ask
# and reports `goirc: state restored`; GOVAULT re-execs clean to its create
# face — bound, asked, never answered: the audit's named gap. The python
# below prints the ten-row report and fails on any unexplained row.

vgate_file script-33.txt <<'EOF'
set GOMAXPROCS=1
vf rm SNAPSHOT.BUNDLE
wm
exec GOTABWM.ELF
EOF

vgate_file script2-33.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-33.txt <<'EOF'
wm
dui
echo rx-audit-e-rest-ok
EOF

vgate_run 35 -- \
    --screen '$RUN_DIR/screen-33' \
    --via-virtio \
    --script '$RUN_DIR/script-33.txt' \
    --script2 '$RUN_DIR/script2-33.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-33.txt' \
    --script3-after 'gotabwm: session live n=2' --script3-delay 8 \
    --script-expect 'rx-audit-e-rest-ok' --timeout 300

vgate_assert 33 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 33 serial-contains 'gotabwm: session load n=2 mode=restore'
vgate_assert 33 serial-contains 'gotabwm: session reexec n=2'
vgate_assert 33 serial-contains 'gotabwm: session exec GOVAULT.ELF'
vgate_assert 33 serial-contains 'gotabwm: session exec GOIRC.ELF'
vgate_assert 33 serial-contains 'gotabwm: session live n=2'
# GOVAULT's row restored no blob — the kind-21 serve line names only
# GOIRC's window.
vgate_assert 33 serial-count 'gotabwm: state restore id=' 1
vgate_assert 33 serial-contains 'goirc: state restored'
vgate_assert 33 serial-contains 'goirc: dial 10.0.0.2 6667 plain'
vgate_assert 33 serial-absent 'goirc: consent ask'
vgate_assert 33 serial-contains 'govault: new vault'
vgate_assert 33 serial-contains 'rx-audit-e-rest-ok'
vgate_assert 33 serial-absent 'goirc: state refused'
vgate_assert 33 serial-absent 'gotabwm: state drop'
vgate_assert 33 serial-absent '[EXC] parking:'
vgate_assert 33 serial-absent 'exited status=139'

# The audit report: one row per app, correlated through the seat's window
# ids (each app's own `open id=` names the window the ask/save/restore
# markers reference). Runs 24-33's serials all live in RUN_DIR. The two
# named gaps ride as expected rows — GOVAULT never had hooks (M156c), and
# GOEMOJI's are wired but its loop never services the ask (M152c) — and a
# hookless row that unexpectedly answers, or a hooked row that loses its
# restore, fails the gate: a finding the card wants named, not a surprise.
vgate_assert 33 python <<'PY'
import os, re, sys
rd = os.environ["RUN_DIR"]

def ser(tag):
    p = os.path.join(rd, "vm-serial-%s.log" % tag)
    if not os.path.exists(p):
        sys.exit("run %s serial missing (%s)" % (tag, p))
    return open(p, errors="replace").read()

# (bin, save run, restore run, app's own restored-evidence marker, why when
# the expectation is not restore=ok, save stage writes /host/APPSTATE.<win>)
APPS = [
    ("GOASSIST.ELF", "24", "25", "goassist: state restored conv=", None, True),
    ("GOPAINT.ELF",  "24", "25", "gopaint: state restored", None, True),
    ("GOSHEET.ELF",  "26", "27", "gosheet: state restored cells=", None, True),
    ("GOREADER.ELF", "26", "27", "goreader: restored page=", None, True),
    ("GOCLOCK.ELF",  "28", "29", "goclock: state restored", None, True),
    ("GOMINE.ELF",   "28", "29", "gomine: state restored size=", None, True),
    ("GOSOL.ELF",    "30", "31", "gosol: restored moves=", None, True),
    ("GOEMOJI.ELF",  "30", "31", None,
     "SaveState wired but the appkit loop never calls PollStateAsk "
     "- the ask is posted and never answered, no blob stored "
     "(M152c #2917 owns the app)", True),
    ("GOIRC.ELF",    "32", "33", "goirc: state restored", None, True),
    ("GOVAULT.ELF",  "32", "33", None,
     "no M125a hooks (shipped pre-protocol; M156c #2933 owns the app)",
     False),
]

# Read-only grant evidence: which mask lacks `file` while the app's save
# stage writes /host/APPSTATE.<win> through the file channel.
masks = {}
for line in open("image/fleet-grants.txt"):
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    cols = line.split("\t")
    if len(cols) >= 3:
        masks[cols[0].strip()] = set(w for w in cols[2].split(",") if w)

def open_ids(s, stem):
    return [int(m) for m in
            re.findall(re.escape(stem + ": open id=") + r"(\d+)", s)]

bad = []
for bin_, stag, rtag, marker, why0, stage in APPS:
    stem = bin_[:-4].lower()
    s, r = ser(stag), ser(rtag)
    ask, save, restore, why = "n", "-", "none", "-"
    ids = open_ids(s, stem)
    if ids:
        wid = ids[-1]
        if re.search(r"gotabwm: state ask id=%d " % wid, s):
            ask = "y"
        m = re.search(r"gotabwm: state save id=%d len=(\d+)" % wid, s)
        if m:
            save = m.group(1)
    if marker is None:
        restore = "none"
        why = why0
    else:
        rids = open_ids(r, stem)
        served = bool(rids) and re.search(
            r"gotabwm: state restore id=%d " % rids[-1], r) is not None
        marked = marker in r
        if served and marked:
            restore = "ok"
        else:
            restore = "fail"
            if not served and not marked:
                why = "blob never served and no restored marker"
            elif not served:
                why = "restored marker printed but the seat never served a blob"
            else:
                why = "seat served a blob but no restored marker"
    f = "-" if not stage else (
        "absent" if "file" not in masks.get(bin_, set()) else "ok")
    print("audit %s ask=%s save=%s restore=%s file=%s why=%s"
          % (bin_, ask, save, restore, f, why))
    if marker is not None and restore != "ok":
        bad.append("%s restore=%s (%s)" % (bin_, restore, why))
    if marker is None and (save != "-" or restore != "none"):
        bad.append("%s answered unexpectedly (save=%s restore=%s)"
                   % (bin_, save, restore))
if bad:
    sys.exit("audit rows off expectation: %s" % "; ".join(bad))
print("audit: ten rows - seven round-trip; GOEMOJI + GOVAULT name their gaps")
PY
