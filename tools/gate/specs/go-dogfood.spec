# go-dogfood.spec -- M69a (issue #1528) class-B gate: the daily-driver beat on
# the DEFAULT Go seat (no `wm` override anywhere in this spec).
#
# Two boots, one beat. Each boot stages a slice of the beat's apps on the same
# default seat, and each slice is phase-gated: the harness forwards the next
# `exec` only after the previous app's own marker says it was HOSTED, so the
# serial order is the beat order and not the scheduler's. The six markers are
# printed by guest programs -- the seat and the apps themselves -- so no staged
# line and no harness echo can produce one (D2).
#
#   boot 01   first-boot GOSH -> exec NOTE.ELF      seat, gosh, note, ok
#   boot 02   exec GOCALC.ELF -> exec WEB.ELF PAGE  seat, calc, page, ok
#
# WHY TWO BOOTS, not one (both limits observed in-tree, neither invented here):
#
#  1. The runner forwards at most THREE command phases per boot (`--script`,
#     `--script2`, `--script3`, each released by its own `-after` marker --
#     host/vm-runner/Sources/VMRunner/main.swift). Four phase-gated execs need
#     four phases. Putting two execs in one phase would leave their declare
#     order to the scheduler, and an ordered assert on a race is a flake, not
#     evidence.
#  2. The seat's PROVEN envelope is three Go runtimes: itself plus two clients
#     (M65d / #1442: 3 kernel + 3x4 Ms + 1 spare; see the maxTicks note in
#     user/go/gotabwm/seat.go). That is an envelope, not a documented failure --
#     four live Go runtimes have not been tried, and #1449 is the record of a
#     different shape entirely (a THIRD SEQUENTIAL exec from one EL0 parent,
#     which M70c-S2 then measured as unreproduced at its head). So each boot
#     stages two client apps, which is also the shape go-wm-default (one app)
#     and go-wm-tabs (two) already prove. Reason 1 alone is a hard limit; this
#     one is the conservative choice inside a proven envelope, and is labelled
#     as such rather than cited as a wall.
#
# The beat is therefore a tour of the default seat: shell+editor together,
# then calculator+browser together. All four apps, one seat, same share.
#
# What each marker actually proves -- stated precisely, because the obvious
# reading of the app markers is stronger than the wire supports:
#
#   dogfood: seat   the seat's own line, after registration AND the one-seat
#                   probe returned: the DEFAULT seat owns the desktop.
#   dogfood: gosh   the APP, on its accepted-declare path only. Read this for
#   dogfood: note   what it is: the seat ANSWERED the declare with the ack's
#   dogfood: calc   applied bit set, i.e. a WM seat is there and the app is on
#                   it -- NOT proof that a tab opened. gotabwm's applyRPC acks
#                   applied=1 on this path whether or not tabs.OpenTab took
#                   (interop.go), and the app cannot see the difference, so
#                   these three lines must not be asked to carry the hosting.
#   dogfood: page   WEB, once, on the first frame of a LAID-OUT page reaching
#                   the scanout -- the page rendered.
#   dogfood: ok     the seat's host-done line, printed only when this boot
#                   actually hosted a tab: the dogfoodHosted latch is set by a
#                   successful tabs.OpenTab alone (interop.go).
#
# HOSTING is therefore pinned where the kernel-side truth lives: the seat's own
# `gotabwm: tab open id=` counter, asserted at TWO per boot below -- the idiom
# go-wm-tabs.spec uses for the same two-tab property. Without that count the
# gate could regress to one hosted app per boot and still pass, since one tab
# sets the latch that `dogfood: ok` hangs on and every app marker above would
# still fire.
#
# The browser is attached with WM_RPC kind 5 (attach), not kind 8
# (declare_fullscreen), so the page keeps the 512x384 geometry the live-web
# gates pin. Attach is what makes the page VISIBLE here: the seat paints the
# blank desktop only while its strip is empty, and that compose-N fill sits
# ABOVE user windows -- an undeclared browser would be silently overpainted.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh        ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gosh.sh           ->  .build/go/GOSH.ELF
#   bash tools/go/build-note.sh           ->  .build/go/NOTE.ELF
#   bash tools/go/build-gocalc.sh         ->  .build/go/GOCALC.ELF
#   bash tools/go/build-web.sh browser    ->  .build/go/WEB.ELF (the name the
#                                             app claims to the WM; the script
#                                             defaults it now)
#   bash tools/go/build-goterm.sh         ->  .build/go/GOTERM.ELF    (boot 04)
#   bash tools/go/build-charmhello.sh     ->  .build/go/CHARMHELLO.ELF (boot 04)
#   bash tools/go/build-files.sh          ->  .build/go/GOFILES.ELF   (boots 05/06/08)
#   bash tools/go/build-gosound.sh        ->  .build/go/GOSOUND.ELF   (boot 07)
#   bash tools/go/build-goedit.sh         ->  .build/go/GOEDIT.ELF    (boots 08/09)
#   bash tools/go/build-goview.sh         ->  .build/go/GOVIEW.ELF    (boot 08)
#   bash tools/go/build-goset.sh          ->  .build/go/GOSET.ELF     (boot 09)
#   bash tools/go/build-goterm.sh already covers boot 09's terminal tab.
#   (the page is the pinned fixture user/go/browser/testdata/gate-page.html,
#    staged as /host/DOGFOOD.HTML; no new fixture)
#
# M69b subscribes to the same six markers for its `--screenshot-after`; see
# docs/testing.md.
#
# M69g (#1558) adds a THIRD boot: GOSH ALONE on the same default Go seat,
# captured after a settle, with a PIXEL assert on its first terminal line.
# The two boots above are marker-only by design; a tab that renders nothing is
# invisible to every one of them, which is exactly how #1558 escaped. Boot 03
# is the falsifiable half — the seed, the seat and the shell are the same, and
# only GOSH is hosted, so the captured frame's tab region is the shell's own
# pixels and nothing else.
#
# M73z (#1638) adds a FOURTH boot: the M73 milestone acceptance, one boot in
# which the default seat drives the whole terminal promise as a user would:
# (a) Enter-summon + the docked Terminal entry (apps.txt:8, dock=true) through
# the launcher -> M73c's honest goterm: markers; (b) a staged share script's
# rows (box-drawing + wide rune, paste >256 B) drag-selected and pushed back
# through GOTERM's bound tty with Ctrl+Shift+C/V (M73e's exact chain) -> every
# line runs; (c) its clear+redraw burst followed by the monitor `tty` line
# reading 0/0 (M73f-1 polarity + M73f-2's line, after the burst settles);
# (d) a LIVE resize -> charmhello's own `charmhello: size` with the NEW
# cells + repaint (M73j — there is no window-edge drag seam under the
# seat: no kernel resize grip, no gotabwm gesture, and the monitor's
# `dui kresize` moves the rect WITHOUT notifying the owner
# (resize_window_keyboard emits no WIN_RESIZE; driving_award.zig:3078
# vs user_resize:1977 — observed serial-04: kresize marker, zero size
# markers after), so the card's "whichever the spec pick supports"
# picks M73j's OWN proven owner seam: one `r` keydown ->
# vi.WinResize(512x384 -> 64x23, go-charmhello's green path) — with
# `r` delivered by --input-key ANCHORED on the seat's own
# `gotabwm: alt-tab id=4` marker, because the seat drains WM_KEY one
# event per composite tick: an in-list `r` 0.25 s behind alt-tab
# reaches the kernel BEFORE focus moves (observed serial-04: the `r`
# fanned at 2002, the pin step forced focus 3 later, zero
# charmhello key markers));
# (e) the captured scanout pixel-asserts
# the rune row's box cells, the wide rune's cell pair, and no ink past col 79
# (M73a-2 + M73g's width wall) at the END of the sequence. Staging rides the
# STARTUP.SH contract (host-side file, silent run before GOTERM's first
# prompt — the serial line cap is 256 B, so a >256 B line cannot be staged
# through the console), and the phases mirror go-wm-hid's proven input set
# (`--via-virtio` alone). The pick of this spec over live-term-depth is
# evidence-made: live-term-depth boots WITHOUT GOTABWM by design (M73d
# geometry, header), so the launcher half cannot exist there; only this spec
# has the default seat + staging + snapshot shape. STARTUP.SH is shared by
# all four boots on purpose: boot 03's pixel pin counts terminal-green pixels
# in row 0 and the first staged row is a dense ASCII echo, so the assertion
# still measures green ink, not a prompt.
#
# M82d2 (#1785) adds boots 05 and 06: the notifications center's POLICY, on the
# LIVE default seat (the demo trigger is removed between boots 04 and 05 -- see
# the hook there). Boot 05 is a user's away-from-keyboard sequence: an app
# raises a toast (GOFILES, a completed copy), the user opens the center and
# turns do-not-disturb ON from its header, the same app raises a SECOND notice
# and it is HELD -- acked to the app, kept in the center's history, never
# painted as a toast. Boot 06 restarts the seat on the same share: the DND
# choice and both notices are still there, restored before the first paint,
# and the reopened center shows them. GOTABWM.DEMO's removal is what makes the
# seat live; nothing else about the default seat is overridden (still no `wm`
# row anywhere). The corrupt-history half of the card is go-wm-default's
# boots 13-16.
#
# M118e (#2483) adds boot 07: GOSOUND's RECORD mode on the default seat. The
# dogfood runner attaches no audio device at all, so the boot pins the
# mode's existence and the device-absent honest outcome (slot 91 ready=0,
# slot 92's ENXIO, no file on the share). The assert-time SoundInProbe
# --sound-in --share leg then repeats the record under a real input stream
# -- the consented shape lands a WAV the host re-verifies off the share
# (header, duration, sha256), the mic-denied shape is the bounded ETIMEDOUT
# refusal with no file: both pinned, exactly as live-sound-record does for
# GOREC.
#
# M124f (#2585) adds boot 08: the cross-app data-flow journey, one boot on
# the LIVE default seat (the demo trigger stayed removed since boot 05),
# exercising every M124 pipe end-to-end the way a user would hit them:
#
#   * an EMPTY SESSION.TABS is staged on boot 07's tag asserts, so the seat
#     restores an empty strip — no starter GOSH — and GOFILES + GOEDIT are
#     exactly the two tabs the ctrl-shift-v split needs (SplitV refuses
#     count!=2).
#   * script a seeds the kernel clipboard (`clip seeded77`) before exec —
#     GOEDIT's ctrl-v then proves the clipboard's READ direction (slots
#     38/39, so every app here is exec'd -u0 for CAP_CLIPBOARD), and
#     GOVIEW's 'c' later proves the typed WRITE direction
#     (`gview: copy mime=image/png` — the M124c receipt).
#   * ONE chords burst does the whole keyboard half while GOEDIT stays
#     focused: ctrl-shift-v splits {GOFILES|GOEDIT} (seat-scope, focus
#     keeps), ctrl-a selects SEL.TXT's 17 bytes (the M124e publish:
#     `goedit: selpub` + `gotabwm: sel pub`), ctrl-v pastes the seeded
#     clipboard over the selection, ctrl-shift-s raises the M124b shared
#     picker seeded "SEL.TXT" — six backspaces clear it (a seventh would
#     climb to /host), a fresh name resolves against the picker's cwd, and
#     the save lands SAVED.TXT on the share, which GOFILES' watch feed
#     reports (`gofiles: watch created SAVED.TXT` — the picker -> /disk ->
#     visible-in-GOFILES leg).
#   * ONE pointer sequence does the whole gesture half: a rail click on
#     GOEDIT's cell pins focus (the drop hit-test resolves an overlap to
#     the focused tab — GOFILES' live rect still spans the release point),
#     press+held move on NOTE.TXT's row arms the M124a drag, and the
#     release over GOEDIT's right pane drops it (`goedit: drop text/plain`
#     + `gofiles: drag end delivered`); a rail click on GOFILES' cell then
#     hands it the keys. NOTE: the seat's content forward does not deliver
#     a right-button press to an SGR app (observed: only b=0/b=32 reports
#     ever print — go-fileman's menu boot ran on the kernel desktop), so
#     M124d is exercised through GOFILES' 'o' handler list on PIC.PNG —
#     the same choose->launch pipe the submenu feeds — typed by
#     --input-string after the rail click; the pick launches GOVIEW.ELF,
#     which is also how the journey stages the image GOVIEW's 'c' then
#     copies (--input-key 8). A run of unpressed hovers gives the boots
#     wall-clock headroom, and the last step middle-clicks inside GOTERM's
#     fullscreen pane delivering the published buffer (`goterm: sel-paste`
#     -> the pasted line submits -> `goterm: line echo sel-live-ok` —
#     M124e cross-app).
#   * script c execs GOTERM only after `gview: copy` — an earlier declare
#     would paint its fullscreen window over the panes mid-gesture. The run
#     ends on `goterm: done status=0` and the cvc-snap pixel assert proves
#     the pasted line painted real ink.
# M123e (#2579) adds no boot: a per-run assert (refusal-pair.py, staged
# below) fails any refusal-shaped serial line -- `rc=-<n>` or a
# `refuse[d]` verb -- that no UI-surface marker answers. The journey's
# observed refusal set (boot 05's `gofiles: clip-sys rc=-7` receipt,
# boot 06's refusal toast, boot 07's `gosound: rec refused ENXIO`) and
# the named non-failure classes are documented in the helper.
#
# M121f (#2569) adds boot 09: the M121 arc's acceptance -- a keyboard-only
# daily-driver journey on the LIVE default seat (the demo trigger stayed
# removed since boot 04's between-run cleanup, and a tag-08 assert below
# empties SESSION.TABS so the strip starts restored-empty). NO pointer
# phase is armed at all: the run carries no --pointer-virtio, and the
# serial is pinned free of the pointer-produced markers (rail-click, the
# tty drag-select pair, the drag/drop family). One chord batch walks the
# surfaces the way a user drives them -- a typed run -> the '?' hint
# overlay -> ctrl+z undo -> the move pair -> pin -> palette exec ->
# close -> reopen -- and the M121d badge's transition lines plus its
# panel pixels pin the focus tracking. Choreography in the boot-09
# block at the end.
#
# exec-order: assert-proven -- every phase gate is anchored on guest output
# (the seat's, an app's, or the kernel's own marker: dogfood: seat ->
# user-el0 reaped -> gotabwm: present (the seat's own first present, reached
# only once NOTE's user window created render demand — boot 04's string
# phase fires here, go-wm-hid's chords fire on this same marker);
# goterm: prompt / dui: term sel end / goterm: done status=0 /
# charmhello: ready are all program markers), and the run ends on
# `charmhello: repainted` — a marker only charmhello prints after
# ActionResized, so a program that never ran still fails the run.
# Boot 09's shape is the same: script phases anchor on dogfood: seat /
# goterm: ready / gotabwm: rail n=3 (both async declares must have landed
# for the rail to reach three), the chord batch releases on
# `goedit: present`, and the script-owned rx echo ends the run only after
# every load-bearing assert has program output to read.

vgate_name go-dogfood "issue #1528 M69a: the DEFAULT Go seat hosts the daily-driver beat (GOSH+NOTE, then GOCALC+WEB) with ordered guest-printed dogfood: markers"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# M76d (#1677): boot 01 also pins the boot-wide splash-to-shell chain. A
# successful seat bind releases the splash silently, so this boot asserts the
# observable kernel/banner/autostart/seat/first-boot/prompt order and that the
# bounded no-seat splash timeout did NOT fire. The negative remains covered by
# live-roadpops boot 01: a share without GOTABWM completes under --timeout 30,
# prints the bounded splash timeout AND '(shim compositing)', and captures the
# returned Road Pops terminal.

# --- boot 01: the shell and the editor on the default seat -----------------
# Phase 1 hands focus away from the seat's startup probe. The default seat
# then restores its missing SESSION.TABS branch and launches the starter GOSH;
# do not explicitly exec GOSH here or the first-boot path is suppressed as a
# duplicate client.
vgate_file script-01a.txt <<'EOF'
dui focus 0
EOF

# Phase 2 waits for the starter's prompt to reach the terminal, then launches
# NOTE as the second client on the same default seat.
vgate_file script-01b.txt <<'EOF'
exec NOTE.ELF
EOF

# Phase 3 waits on the seat's `dogfood: ok` (host-done), so the beat slice has
# finished before the run ends; the end marker itself is script-owned.
vgate_file script-01c.txt <<'EOF'
echo rx-dogfood-01-ok
EOF

# M79a (#1704): the seat's bounded demo choreography (auto-close, the
# reorder/pin/split chain, the run budget + exit sweep) is DEMO mode, opted
# in by the PRESENCE of /host/GOTABWM.DEMO. This spec's boots autostart the
# seat and its acceptance chains are written against that choreography (boot
# 04 ends on the budget + sweep), so the trigger is seeded here like any
# other share fixture. A daily session never stages this file and gets the
# live seat (go-wm-seat run 05 proves that path end to end).
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
for name, how in (("GOTABWM.ELF", "build-gotabwm.sh"),
                  ("GOSH.ELF", "build-gosh.sh"),
                  ("NOTE.ELF", "build-note.sh"),
                  ("GOCALC.ELF", "build-gocalc.sh"),
                  ("WEB.ELF", "build-web.sh browser WEB"),
                  ("GOTERM.ELF", "build-goterm.sh"),
                  ("CHARMHELLO.ELF", "build-charmhello.sh"),
                  ("GOFILES.ELF", "build-files.sh"),
                  ("GOSOUND.ELF", "build-gosound.sh"),
                  ("GOEDIT.ELF", "build-goedit.sh"),
                  ("GOVIEW.ELF", "build-goview.sh"),
                  ("GOSET.ELF", "build-goset.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name))
shutil.copy(os.path.join("user", "go", "browser", "testdata", "gate-page.html"),
            os.path.join(share, "DOGFOOD.HTML"))
# The whole point of this spec is the COMPILED default seat: a persisted `wm`
# row would test the setting instead of the daily driver.
if os.path.exists(os.path.join(share, "SETTINGS.TXT")):
    sys.exit("SETTINGS.TXT already present in the share; the dogfood beat must "
             "boot with no persisted `wm`")
print("staged GOTABWM/GOSH/NOTE/GOCALC/WEB/GOTERM/CHARMHELLO/GOFILES/GOSOUND/"
      "GOEDIT/GOVIEW/GOSET + DOGFOOD.HTML from the pinned gate-page.html fixture")
PY

# M82d2 (#1785): boot 05's notice sender is GOFILES.ELF (its completed copy
# raises a toast, go-wm-seat run 06's adopter), so stage the tree its copies
# need. Directories sort first: DIR1 is entry 0, DIR2 entry 1, SOURCE.TXT
# entry 2 -- which is what the key batches in boot 05 count on. Two
# destinations because a paste never overwrites: the SECOND notice needs a
# copy that succeeds, and the same file cannot be pasted twice into one dir.
vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
notify = os.path.join(share, "NOTIFY")
for d in ("DIR1", "DIR2"):
    os.makedirs(os.path.join(notify, d), exist_ok=True)
with open(os.path.join(notify, "SOURCE.TXT"), "w") as f:
    f.write("notify-policy-payload\n")
print("staged NOTIFY/{DIR1,DIR2,SOURCE.TXT} for the M82d2 notify boots")
PY
# M123e (#2579): the refusal-pairing audit. Every boot's serial is scanned by
# refusal-pair.py (written into $RUN_DIR here, asserted per run below): any
# `rc=-<n>` or `refuse[d]` line must pair with a UI-surface marker in the same
# boot -- the seat's M123a refusal toast, its notify surfaces, or the app's own
# M123b/M123d banner/empty markers. The named non-failure classes (pre-UI init,
# seat->app protocol acks, capability vocabulary, receipts) are documented in
# the helper -- listed, never silently swallowed.
vgate_file refusal-pair.py <<'EOF'
# M123e (#2579) -- no serial-only refusals in the dogfood journey.
#
# Scans the run's serial ($VG_SER; tag 07 also scans the SoundInProbe sub-leg's
# $RUN_DIR/gosound-rec-serial.log) for refusal-shaped lines and fails when one
# carries no UI-surface marker.
#
# Refusal-shaped: `rc=-<n>` (a guest marker reporting a negative kernel return)
# or a refuse/refused verb.
#
# PAIRED when a UI marker follows the line in the same serial:
#   - seat: `gotabwm: refusal` (the M123a toast, incl. act/dedupe lines),
#     `gotabwm: notify paint`, `gotabwm: notify held`
#   - same app prefix: `<app>: banner`, `<app>: banner act`, `<app>: empty`
#
# Self-paired (the line IS the UI marker's serial receipt):
#   - `gotabwm: refusal*` -- the toast's own marker
#   - `<app>: banner*` / `<app>: empty` -- the banner/empty-state markers
#   - `goedit: state restored` -- the re-exec'd editor's restored tab is
#     the visible surface its missing-file rc=-6 read reports on (boot 09:
#     the reopened GOEDIT restores its buffer instead of re-showing the
#     empty plate, so `empty` never pairs its second read)
#   - `gosound: * refused` / `gosound: rec write refused rc=` -- GOSOUND parks
#     its refused state in-window (stRefused; "Empty and refused park in the
#     window", user/go/sound/main.go), so the marker reports a visible state
#
# Named non-failures (listed, not swallowed):
#   init: refuse missing-init    pre-UI boot path; no seat exists yet, the
#                                marker IS the record
#   gotabwm: rpc refuse          seat->app RPC acks -- the kind's "not now";
#   gotabwm: sel refuse          the app re-polls. Flow control, not failures
#   cap: refuse                  the capability table's refusal-VOCABULARY
#                                line, not an event
#   gofiles: clip-sys rc=        M124c's best-effort file:// URI publish to the
#                                kernel clipboard: EACCES under a cap-less
#                                exec is the designed receipt (user/go/files/
#                                state.go); the copy the user asked for worked
#
# A `<app>: notify refused` line pairs the same way -- a following
# `gotabwm: notify` marker means the seat still queued/painted the notice.
import bisect, os, re, sys

REFUSAL = re.compile(r"rc=-\d|\brefus(?:e|ed|al)\b")
SELF = ("gotabwm: refusal", ": banner", ": empty",
        "gosound: rec refused", "gosound: meter refused", "gosound: refused",
        "gosound: rec write refused")
EXEMPT = ("init: refuse missing-init", "gotabwm: rpc refuse",
          "gotabwm: sel refuse", "cap: refuse",
          "gofiles: clip-sys rc=")
SEAT_UI = ("gotabwm: refusal", "gotabwm: notify paint", "gotabwm: notify held")
APP_UI = (": banner", ": empty", "goedit: state restored")
PREFIX = re.compile(r"^([a-z0-9]+):")


def scan(lines, label):
    seat_at = [i for i, l in enumerate(lines) if any(s in l for s in SEAT_UI)]
    app_at = {}
    for i, l in enumerate(lines):
        if any(s in l for s in APP_UI):
            m = PREFIX.match(l)
            if m:
                app_at.setdefault(m.group(1), []).append(i)
    paired = selfp = exempt = 0
    bad = []
    for i, line in enumerate(lines):
        if not REFUSAL.search(line):
            continue
        if any(x in line for x in EXEMPT):
            exempt += 1
            continue
        if any(x in line for x in SELF):
            selfp += 1
            continue
        ok = bisect.bisect_right(seat_at, i) < len(seat_at)
        if not ok:
            m = PREFIX.match(line)
            if m and m.group(1) in app_at:
                ok = bisect.bisect_right(app_at[m.group(1)], i) < len(
                    app_at[m.group(1)])
        if ok:
            paired += 1
        else:
            bad.append(line.strip()[:160])
    print("%s: refusal pairing -- %d paired, %d self-paired UI markers, "
          "%d named non-failures, %d UNPAIRED"
          % (label, paired, selfp, exempt, len(bad)))
    for b in bad:
        print("  UNPAIRED refusal: " + b)
    return bad


fail = 0
fail += len(scan(
    open(os.environ["VG_SER"], errors="replace").read().splitlines(),
    "serial " + os.environ["VG_TAG"]))
tag = os.environ["VG_TAG"]
if tag == "07":
    extra = os.path.join(os.environ["RUN_DIR"], "gosound-rec-serial.log")
    if not os.path.exists(extra):
        sys.exit("gosound-rec-serial.log missing (the SoundInProbe assert "
                 "produces it before this leg)")
    fail += len(scan(open(extra, errors="replace").read().splitlines(),
                     "gosound-rec"))
if fail:
    sys.exit("%d serial-only refusal line(s) -- every rc<0/refusal in the "
             "dogfood journey must carry a UI marker" % fail)
EOF

# M124f (#2585): boot 08's FLOW tree — exactly three name-sorted files so the
# rows the journey presses are deterministic: NOTE.TXT row 0 (the drag's
# payload: 8 bytes so `n=` pins the splice), PIC.PNG row 1 (the Open With
# target AND the image GOVIEW copies — the repo's 160x120 decoder fixture
# at 420 bytes, inside the kernel clipboard's 512 bound), SEL.TXT row 2
# (the file GOEDIT opens: its trailing newline means a primary-selection
# paste into GOTERM's line editor SUBMITS — `goterm: line echo sel-live-ok`
# is the end-to-end proof the bytes reached the shell).
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
flow = os.path.join(share, "FLOW")
os.makedirs(flow, exist_ok=True)
with open(os.path.join(flow, "NOTE.TXT"), "w") as f:
    f.write("drag-me\n")
with open(os.path.join(flow, "SEL.TXT"), "w") as f:
    f.write("echo sel-live-ok\n")
png = os.path.join("tests", "fixtures", "png", "viewer_160x120.png")
if not os.path.exists(png):
    sys.exit("PNG fixture missing (expected " + png + ")")
shutil.copy(png, os.path.join(flow, "PIC.PNG"))
print("staged FLOW/{NOTE.TXT,PIC.PNG,SEL.TXT} for the M124f journey boot")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen-01' \
    --script '$RUN_DIR/script-01a.txt' \
    --script-after 'gotabwm: win focus' \
    --script2 '$RUN_DIR/script-01b.txt' \
    --script2-after 'gosh: prompt' \
    --script3 '$RUN_DIR/script-01c.txt' \
    --script3-after 'dogfood: ok' \
    --script-expect 'rx-dogfood-01-ok' --timeout 300

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
# The DEFAULT seat, chosen by the compiled default and nothing else.
vgate_assert 01 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: seat-taken'
# dogfood: seat -- the seat's own announcement, after both returned.
vgate_assert 01 serial-contains 'dogfood: seat'
vgate_assert 01 serial-contains 'text: boot banner presented'
vgate_assert 01 serial-contains 'gotabwm: first-boot workspace'
vgate_assert 01 serial-contains 'gosh: prompt'
vgate_assert 01 serial-absent 'splash: seat present not observed within 3s'

# --- GOSH, HOSTED as a GOTABWM tab (not Zig TABWM) --------------------------
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gotabwm: rpc declare id='
vgate_assert 01 serial-contains 'gosh: declare accepted'
vgate_assert 01 serial-contains 'dogfood: gosh'
vgate_assert 01 serial-contains 'gotabwm: tab open id='
vgate_assert 01 serial-contains 'gotabwm: host focus id='
vgate_assert 01 serial-contains 'gotabwm: host view id='

# --- NOTE, the same seat, the same strip -----------------------------------
vgate_assert 01 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert 01 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert 01 serial-contains 'dogfood: note'

# --- the slice's own close, then the run's end marker ----------------------
vgate_assert 01 serial-contains 'gotabwm: host done'
vgate_assert 01 serial-contains 'dogfood: ok'
vgate_assert 01 serial-contains 'rx-dogfood-01-ok'
# THE central property of this gate, and the one no app marker can carry: TWO
# tabs opened on the one strip. Read `gotabwm: tab open id=` (printed only when
# tabs.OpenTab returned true) at least twice -- the idiom go-wm-tabs.spec uses
# (lines 185/446). Without it, a regression to one hosted app per boot would
# pass every assert above: one OpenTab sets the dogfoodHosted latch `dogfood:
# ok` hangs on, and each app's own marker fires off the ack alone.
vgate_assert 01 serial-count 'gotabwm: tab open id=' 2
# The Zig fallback seat's autostart line is what this rules out at runtime (the
# line-start check in the python block covers its own marker). It guards the
# compiled `wm_default` constant rather than the seat's behaviour, so read it as
# "the default was compiled in", not as "the fallback engine ran".
# NOT `serial-absent 'tabwm: registered'`: that is a SUBSTRING match (grep -F)
# and `gotabwm: registered` contains it, so the assert could never pass.
vgate_assert 01 serial-absent 'wm: autostart tabwm'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The order, at LINE START (a staged line that merely contains a marker cannot
# satisfy it -- the same reason go-sh.spec anchors its typed markers). The
# second half of the beat must be ABSENT from this boot: without that, a run
# that printed every marker off one app could pass as an ordered beat.
vgate_assert 01 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()


def at(marker):
    m = re.search(r"(?m)^" + re.escape(marker), ser)
    return -1 if m is None else m.start()


want = ["dogfood: seat", "dogfood: gosh", "dogfood: note", "dogfood: ok"]
pos = [(w, at(w)) for w in want]
missing = [w for w, i in pos if i < 0]
if missing:
    sys.exit("marker(s) never printed at line start: " + ", ".join(missing))
order = [w for w, _ in sorted(pos, key=lambda p: p[1])]
if order != want:
    sys.exit("beat order = " + " < ".join(order) + " want " + " < ".join(want))
for other in ("dogfood: calc", "dogfood: page"):
    if at(other) >= 0:
        sys.exit(other + " appeared in the shell/editor boot")
# The Zig seat's own marker, at line start: `serial-absent 'tabwm: registered'`
# is unusable here because `gotabwm: registered` contains it.
if re.search(r"(?m)^tabwm: registered", ser):
    sys.exit("the Zig TABWM seat registered: this is not the default Go seat")
print("boot 01 order ok: " + " < ".join(want) +
      " (and the calculator/browser half is absent)")
PY

# M76d: the splash success path is intentionally silent. Pin the complete
# observable startup chain by line index, including the banner being presented
# while the splash holds scanout and the first-boot shell's prompt after the
# seat registers. The absent timeout above distinguishes the silent seat bind
# from live-roadpops' bounded no-seat fallback.
vgate_assert 01 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()
chain = [
    "VirelaiOS kernel has seized control.",
    "text: boot banner presented",
    "wm: autostart gotabwm (settings wm=gotabwm)",
    "gotabwm: registered",
    "gotabwm: first-boot workspace",
    "gosh: prompt",
]
positions = []
for marker in chain:
    match = re.search(r"(?m)^" + re.escape(marker) + r"$", ser)
    if match is None:
        sys.exit("M76d startup marker missing: " + marker)
    positions.append(match.start())
if positions != sorted(positions) or len(set(positions)) != len(positions):
    sys.exit("M76d startup chain out of order: " + repr(list(zip(chain, positions))))
if "splash: seat present not observed within 3s" in ser:
    sys.exit("M76d seat-bound boot took the no-seat splash timeout path")
print("M76d boot 01 chain ordered: " + " -> ".join(chain) +
      " (silent splash handoff; no bounded-timeout marker)")
PY

# D1, re-checked between the boots (the staging guard only saw the pre-run
# share). Boot 01 must not have left a `wm` row behind: the moment it does, boot
# 02 tests the SETTING while every assert it makes still passes.
vgate_assert 01 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
p = os.path.join(share, "SETTINGS.TXT")
if os.path.exists(p):
    rows = [l for l in open(p, errors="replace").read().splitlines()
            if l.strip().startswith("wm=")]
    if rows:
        sys.exit("FAIL: boot 01 persisted a `wm` row (%s) - boot 02 would boot "
                 "the SETTING, not the compiled default seat" % rows)
    print("between the boots: SETTINGS.TXT exists and carries no `wm` row, so "
          "boot 02 boots the compiled default")
else:
    print("between the boots: no SETTINGS.TXT on the share at all, so boot 02 "
          "boots the compiled default")
PY

# Boot 02 keeps the strip clean of boot 01's apps. M120b (#2559): a restored
# session is LIVE now — the seat re-execs every backed row — so boot 01's
# [Sh, notes.txt] file would spawn a real NOTE.ELF in the calc/browser boot,
# and its `dogfood: note` is asserted ABSENT below. A count=0 v2 file reads
# as restored (no first-boot starter, no `dogfood: gosh` either) with
# nothing to re-exec. The fix was a delete before M120b, when restored rows
# stayed dead placeholders; an empty file is the same intent one step over.
vgate_assert 01 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x02\x00\x00\x00\x00\x00")
print("between-run cleanup: empty SESSION.TABS for boot 02 "
      "(restored-empty: no re-exec fan-out, no starter)")
PY

# M123e (#2579): no serial-only refusals in this boot -- every `rc=-<n>` /
# `refuse[d]` line pairs with a UI-surface marker (rules in refusal-pair.py).
vgate_assert 01 python <<'PY'
import os
exec(compile(open(os.path.join(os.environ["RUN_DIR"], "refusal-pair.py")).read(),
             "refusal-pair.py", "exec"))
PY

# --- boot 02: the calculator and the browser on the same default seat -------
# Same share, same compiled default. D1 says the seat is the COMPILED default
# and not a setting, and boot 02 is the boot where that could silently stop
# being true: if anything ever began persisting a `wm` row, boot 01 would write
# it, boot 02 would boot from the setting, and every assert in this run would
# still pass. So the share is re-checked BETWEEN the two boots rather than
# trusting the staging guard, which only ever saw the pre-run share.
vgate_file script-02a.txt <<'EOF'
set GOMAXPROCS=1
exec GOCALC.ELF
EOF

vgate_file script-02b.txt <<'EOF'
exec WEB.ELF /host/DOGFOOD.HTML
EOF

vgate_file script-02c.txt <<'EOF'
echo rx-dogfood-02-ok
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --script '$RUN_DIR/script-02a.txt' \
    --script-after 'dogfood: seat' \
    --script2 '$RUN_DIR/script-02b.txt' \
    --script2-after 'dogfood: calc' \
    --script3 '$RUN_DIR/script-02c.txt' \
    --script3-after 'dogfood: ok' \
    --script-expect 'rx-dogfood-02-ok' --timeout 300

vgate_assert 02 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'dogfood: seat'

# --- GOCALC, hosted ---------------------------------------------------------
vgate_assert 02 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 02 serial-contains 'gotabwm: rpc declare id='
vgate_assert 02 serial-contains 'gocalc: declare accepted'
vgate_assert 02 serial-contains 'dogfood: calc'

# --- WEB shows a page, on the seat's own strip ------------------------------
vgate_assert 02 serial-contains 'exec: loaded WEB.ELF'
vgate_assert 02 serial-contains 'web: url /host/DOGFOOD.HTML'
vgate_assert 02 serial-contains 'web: parse nodes='
vgate_assert 02 serial-contains 'web: layout blocks='
vgate_assert 02 serial-contains 'web: paint items='
vgate_assert 02 serial-contains 'dogfood: page'
vgate_assert 02 serial-contains 'web: ready'
# The attach (kind 5) the browser sends, acknowledged by the seat: the page is
# on the strip -- the only arrangement in which the seat stops blanking over it.
vgate_assert 02 serial-contains 'gotabwm: rpc attach id='
vgate_assert 02 serial-contains 'gotabwm: tab open id='

vgate_assert 02 serial-contains 'gotabwm: host done'
vgate_assert 02 serial-contains 'dogfood: ok'
vgate_assert 02 serial-contains 'rx-dogfood-02-ok'
# Two tabs again -- the calculator's declare and the browser's attach. See boot
# 01 for why this count, and not the app markers, is the hosting proof.
vgate_assert 02 serial-count 'gotabwm: tab open id=' 2
# See boot 01: `tabwm: registered` is a substring of `gotabwm: registered`.
vgate_assert 02 serial-absent 'wm: autostart tabwm'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

vgate_assert 02 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()


def at(marker):
    m = re.search(r"(?m)^" + re.escape(marker), ser)
    return -1 if m is None else m.start()


want = ["dogfood: seat", "dogfood: calc", "dogfood: page", "dogfood: ok"]
pos = [(w, at(w)) for w in want]
missing = [w for w, i in pos if i < 0]
if missing:
    sys.exit("marker(s) never printed at line start: " + ", ".join(missing))
order = [w for w, _ in sorted(pos, key=lambda p: p[1])]
if order != want:
    sys.exit("beat order = " + " < ".join(order) + " want " + " < ".join(want))
for other in ("dogfood: gosh", "dogfood: note"):
    if at(other) >= 0:
        sys.exit(other + " appeared in the calculator/browser boot")
if re.search(r"(?m)^tabwm: registered", ser):
    sys.exit("the Zig TABWM seat registered: this is not the default Go seat")
print("boot 02 order ok: " + " < ".join(want) +
      " (and the shell/editor half is absent)")
PY

# Same neutralization for boot 03 (M120b #2559): boot 02's [Calc, web] file
# would otherwise re-exec a real GOCALC.ELF into the GOSH pixel boot — an
# extra hosted tab the scanout assert was never written around. Empty file,
# same suppression.
vgate_assert 02 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x02\x00\x00\x00\x00\x00")
print("between-run cleanup: empty SESSION.TABS for boot 03")
PY

# M123e (#2579): no serial-only refusals in this boot -- every `rc=-<n>` /
# `refuse[d]` line pairs with a UI-surface marker (rules in refusal-pair.py).
vgate_assert 02 python <<'PY'
import os
exec(compile(open(os.path.join(os.environ["RUN_DIR"], "refusal-pair.py")).read(),
             "refusal-pair.py", "exec"))
PY

# --- boot 03: the shell tab's PIXELS on the default seat (M69g, #1558) ------
# Same compiled default seat, same share, GOSH alone. The capture is released
# by a MONITOR echo 4 s after `gosh: prompt` (the M69b recipe: the prompt is
# written to the tty, and the compositor paints it on the next composite), so
# the frame holds a settled tab rather than the boot frame.
#
# What the marker asserts is the geometry, not just "it ran": GOSH declares
# full-viewport, so its window is the whole scanout, and the kernel draws a
# window-bound terminal's grid starting at its title-band height (16 device
# rows). The shell's fresh prompt is therefore the ONLY text on the first
# grid line, at device y 16..31 (M73l #1661: cell_h=16 — was 16..23 at
# 8px cells). Before the #1558 fix GOTABWM's own 96x64
# client-death probe window (8,8,96,64) painted its chrome over that band and
# the region held no terminal-green pixels at all (measured: 55, all of it
# anti-aliasing from the probe's own white title text); with the fix it holds
# the prompt (measured: 578 across repeats).
vgate_file script-03a.txt <<'EOF'
set GOMAXPROCS=1
exec GOSH.ELF
EOF

vgate_file script-03b.txt <<'EOF'
echo shot-gosh-pixels
EOF

vgate_file script-03c.txt <<'EOF'
echo rx-dogfood-03-ok
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --screenshot-after 'shot-gosh-pixels' \
    --script '$RUN_DIR/script-03a.txt' \
    --script-after 'dogfood: seat' \
    --script2 '$RUN_DIR/script-03b.txt' \
    --script2-after 'gosh: prompt' --script2-delay 4 \
    --script3 '$RUN_DIR/script-03c.txt' \
    --script3-after 'shot-gosh-pixels' \
    --script-expect 'rx-dogfood-03-ok' --timeout 300

vgate_assert 03 serial-contains 'dogfood: seat'
vgate_assert 03 serial-contains 'gotabwm: tab open id='
vgate_assert 03 serial-contains 'gosh: prompt'
vgate_assert 03 serial-contains 'rx-dogfood-03-ok'
vgate_assert 03 serial-absent 'wm: autostart tabwm'
vgate_assert 03 serial-absent '[EXC] parking:'

# THE pixel assert. Scale the capture (the window capture is 2x the 1280x720
# scanout) instead of pinning counts to one backing scale, and count only
# GREEN-dominant pixels: the probe window's chrome that used to occupy this
# band is white-on-grey, so a chrome-green tint cannot pass this by accident.
vgate_assert 03 snapshot 'screen-03-after' <<'PY'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
pos = 8; idat = b''; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b'IHDR':
        w, h, bd, ct = struct.unpack('>IIBB', data[:10])
    elif typ == b'IDAT':
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

scale = w / 1280.0
# The tab's first terminal line: device rows 17..29 (inside the 16-row
# grid cell that starts at the kernel's 16-row title band — M73l #1661
# cell_h=16), columns 1..55 — the
# "gosh> " prompt and its block cursor.
green = 0
for y in range(int(17 * scale), int(30 * scale)):
    for x in range(int(1 * scale), int(56 * scale)):
        r, g, b = px(x, y)
        if g > r + 30 and g > b + 30:
            green += 1
print("terminal-green pixels on the tab's first line: %d" % green)
assert green >= 200, ("GOSH's tab shows no prompt text (%d green pixels on "
                      "the first terminal line) - the tab is blank" % green)
PY

# Between-run cleanup for boot 04, on THIS tag's asserts: boots 01-03 share
# one RUN_DIR, and the seat's close writes SESSION.TABS (writeSession,
# once-only save-on-exit -- observed: boot 01 `session write n=2`). Under
# M120b (#2559) a restored row is RE-EXEC'd on the next boot — a live app
# boot 04 never asked for — so the tag-02 cleanup above already leaves boot
# 03 an EMPTY v2 file (no `session load` marker prints for count=0), and
# this delete keeps boot 04's Enter-summon on an empty strip. The setup
# hooks all run before boot 01 (vgate.sh's setup loop), so the delete has
# to live HERE: the run/assert loop evaluates tag-03 asserts after run 03
# and before run 04 (vgate.sh tag filter). The harness itself uses this
# between-run slot for WINDOWS.SAV (`rm -f "$SHARE/WINDOWS.SAV"` before
# each run); this is the boot-04-specific instance of that pattern.
vgate_assert 03 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE")
if not share:
    sys.exit("no armed share exported to the assert (vgate_share arm?)")
st = os.path.join(share, "SESSION.TABS")
if not os.path.exists(st):
    sys.exit("boot 03's GOSH tab writes SESSION.TABS (declare mutates) — "
             "the file is gone at between-run cleanup time; re-check the "
             "strip assumption before moving this cleanup")
os.remove(st)
assert not os.path.exists(st), "SESSION.TABS survived removal"
print("between-run cleanup: removed SESSION.TABS "
      "(boot 04 summons on an empty strip)")
PY

# M123e (#2579): no serial-only refusals in this boot -- every `rc=-<n>` /
# `refuse[d]` line pairs with a UI-surface marker (rules in refusal-pair.py).
vgate_assert 03 python <<'PY'
import os
exec(compile(open(os.path.join(os.environ["RUN_DIR"], "refusal-pair.py")).read(),
             "refusal-pair.py", "exec"))
PY

# --- boot 04: THE M73 ACCEPTANCE (M73z, #1638) ------------------------------
# One boot, the default seat, the user's actual sequence. Every phase chains
# off a guest-printed marker:
#   user-el0 reaped -> script-04a: GOMAXPROCS + exec NOTE.ELF + the stage
#                     marker. NOTE is the seat's wake-up call: its USER
#                     window (owner>1) creates render demand, so the kernel
#                     starts the composite-tick cadence and the seat reaches
#                     `gotabwm: present` (observed run 1: a boot with no
#                     user window ever — the kernel demo id2 is owner=1 —
#                     sits at tick=0/present=0 forever and no input phase
#                     can be trusted to land). NOTE declares as the rail's
#                     ONLY tab (boot 03's tag-03 assert above deletes
#                     SESSION.TABS between runs: restored ids are
#                     placeholders that are not kernel windows, so
#                     closeHosted would fail on them and the strip could
#                     never empty), arming the seat's own 16-tick hostTicks
#                     choreography: with n==1 it counts down, then
#                     closeHosted closes NOTE's real id and prints
#                     `gotabwm: host close id=` + `gotabwm: tab close id=`
#                     (tabs.go / interop.go). Only then is the strip empty
#                     for the Enter-summon below. `exec` returns to the prompt
#                     (go-wm-hid run 03: `virelai>` prints right after its
#                     `exec GOTABWM.ELF`), so the shell idle loop — which
#                     is what pumps the queue-3 completions into
#                     input.decode_keyboard_report (main.zig claim 9588) —
#                     is live again before any key is injected.
#   gotabwm: tab close id= -> --input-string Enter + `term` + Enter:
#                     Enter-summons the launcher (tabs.Count()==0, hid.go's
#                     M71e path), filters to the DOCKED Terminal entry
#                     (apps.txt:8) and execs it — the same handleWmKey
#                     handlers go-wm-hid proves live via chords after
#                     `gotabwm: present` (go-wm-hid.spec input-chords-after,
#                     green 4/4 in this worktree); string and chords are the
#                     same EvWmKey fan at the kernel. GOTERM reuses NOTE's
#                     freed slot (driving_award scans first-free ids), so
#                     with GOTERM holding it, charmhello opens as id=4
#   goterm: prompt  -> --pointer-virtio drag over the staged rows: STARTUP.SH
#                     ran its rows silently before this first prompt (M49
#                     SD5 kernel selection -> `dui: term sel end`). The
#                     window IS fullscreen: the serial pins BOTH
#                     `open: id=3 rect=64,48 640x400` (the exec) and then
#                     `gotabwm: host view id=3` — the seat's declare
#                     handler proposes the full viewport and
#                     SetWindowRect(0,0,1280,720) returned 0 (interop.go;
#                     asserted in the chain below from after launcher
#                     open, so it is GOTERM's proposal, not NOTE's). That
#                     is the same shape (e) already probes, and
#                     live-term-depth run 02 proved the client origin
#                     empirically (a 64,48-based drag landed row4/col8);
#                     this run's `dui` dump is the authority: `dui[6]:
#                     user rect=0,0,1280,720 owner=3` — origin 0,0.
#                     title_bar_h=16 (wnd_core.zig), cell 8x16
#                     (font_metrics): content top = 16, so the five
#                     staged rows occupy y16..95 and prompt row 5
#                     y96..111.
#                     press (4,28)=row0col0 — y28 clears BOTH the title
#                     band (y0..15) and the seat's 22px rail band
#                     (RailHeight=22, tabs.go) — release (636,84) =
#                     row4col79 selects lines 0..4 = 274 B > 256 and
#                     stops above the prompt row so no PS1 text joins
#                     the selection. Geometry was NEVER the blocker:
#                     observed serial-04 had the press forwarded
#                     (`gotabwm: ptr` x7) with zero sel markers because
#                     CHARMHELLO's fullscreen face sat TOPMOST and its
#                     M73i mouse capture (?1000/?1006) makes
#                     mouseOwnsAt true there — mouse reports, never
#                     selection (`tty: paste 0 bytes`). The pointer
#                     phase is therefore gated on `charmhello: ready`
#                     and opens with the rail click, which RAISES
#                     GOTERM above charmhello before the press.
#                     script3
#                     fires on this same marker: `exec CHARMHELLO.ELF`
#                     lands n==2 BEFORE the seat's 16-tick countdown
#                     would close GOTERM (observed r7: `host close id=3`
#                     between ptr 3 and 4 — the chords then found no
#                     focused terminal, so no copy and no paste).
#   dui: term sel end -> --input-chords ctrl-shift-c, ctrl-shift-v,
#                     return, alt-tab — then --input-key 15 (`r`),
#                     anchored on alt-tab's marker (see below). The
#                     first three fire with
#                     focus=3 (the pointer phase's rail click — see
#                     (b) — pulled focus off charmhello, whose declare
#                     steals it): applyRailClick -> focusHosted ->
#                     WmctlTaskbarClick refocuses AND RAISES GOTERM
#                     (id=3, marker `gotabwm: rail-click id=3`);
#                     focus changes never clear the kernel selection
#                     (sel_* clears only on reset/alt/resize/search,
#                     terminal.zig:539/724/1164/1379/1502), so the
#                     copy chord lands in the focused-terminal block,
#                     not seat-gated
#                     (input.zig:576/583), so they copy the >256 B
#                     selection off the terminal and paste it through GOTERM's
#                     bound tty (GOSH requests DECSET 2004 at startup, so
#                     the paste lands bracketed \e[200~..\e[201~ and the
#                     chord's return submits the tail — input.zig:583,
#                     live-term-depth.spec:15) — M73e's exact chain.
#                     WAS BLOCKED under the seat (finding on #1629, seam
#                     #1688): selection began only inside pointer_tick
#                     AFTER the wm_owns_input return, and handleWmPointer
#                     forwarded no content pointer events — observed r6:
#                     gotabwm: ptr x4, zero sel markers. The seam landed
#                     in PR #1694 (wm_content_pointer + the seat's content
#                     forward, slot-65 cmd 15): the drag relays into
#                     content_pointer_pass, proven green by
#                     live-term-depth run 02 (sel begin/end + copy 259 B
#                     through the forward). The first pasted row runs `clear` (the
#                     clear+redraw burst, (c)), the next re-prints the rune
#                     row at row 0 ((e)'s pixels). One more chord
#                     follows the return: alt-tab — under a LIVE seat
#                     input.zig only sets alt_tab_pending when
#                     !wm_owns_input, so this is the SEAT's own
#                     applyAltTab; the strip is {3,4}, next-from-3 = 4,
#                     marker `gotabwm: alt-tab id=4` (serial-04's
#                     `dui: alt-tab` was the SHIM, after maxTicks 48
#                     had already killed the seat and its committed
#                     charmhello received `tty: paste 277 bytes`) —
#                     which lands focus on charmhello. `r` is deliberately
#                     NOT the list's fifth chord: the seat drains WM_KEY
#                     ONE event per composite tick (observed serial-04 fan
#                     prints lagging HID receipt: copy 1729/1772, paste
#                     1747/1833, alt 1943, r 2002), so an in-list `r`
#                     0.25 s behind alt-tab hits the kernel while focus is
#                     still 3 and lands in GOSH's line editor — silent,
#                     no marker anywhere. --input-key 15 instead waits on
#                     alt-tab's OWN marker (printed only after
#                     focusHosted(4) -> WmctlTaskbarClick set focus=4),
#                     so the delivered keydown -> charmhello's key
#                     handler -> vi.WinResize(512,384) -> the M73j size
#                     marker (d).
#   charmhello: size 64x23 -> script-04b (2 s delay: the resize's
#                     size+repaint print back-to-back, and 2 s keeps
#                     the paste burst definitively behind it): the
#                     monitor `tty` line (0/0 — the card's (c)), the
#                     `dui` registry dump (geometry evidence), then
#                     `dui lower 4` so (e)'s capture reads GOTERM's
#                     row 0, not charmhello's resized face.
#                     (script3 already fired at prompt:
#                     its n==2 declare freezes the countdown that closed
#                     GOTERM mid-drag in r7 and arms the two-tab
#                     choreography's hidChordHold=32 grace window —
#                     raised 20 -> 32 for M73z so the first destructive
#                     step (n==2 + hold + 7 steps ~ tick 68) lands past
#                     this chain's expect; maxTicks likewise 48 -> 90 in
#                     seat.go.)
#   dui lower: lowered=4 -> script-04b's last line dropped charmhello
#                     behind GOTERM (its 512x384 face would cover the
#                     rune row), strictly after size+repaint (script2
#                     gates on that size marker) — so the harness
#                     captures the scanout HERE; this last marker is
#                     the run's expect and the screenshot barrier.
#
# STARTUP.SH is GENERATED into the share by the hook below (the serial line
# cap is 256 B — observed run 1: `error: input refused: line longer than 256
# bytes` — so a >256 B selection can never be staged through the console;
# the share file is bounded 2048 B/file by the startup contract instead).
# Its rows are DOUBLE-echoed so the screen shows runnable commands, and the
# selected rows together exceed 256 B (the M73e unit: live-term-depth's
# 259 B came from 20 screen rows the same way — a single on-screen row caps
# at ~240 B with the kernel's glyph widths).
vgate_file STARTUP.SH <<'EOF'
echo echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
echo clear
echo echo ┌─┐你 ppppppppppppppppppppppppppppppppppppppppppppppppppppppp
echo echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
echo echo cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
EOF

# The hook computes the SELECTION host-side (the double-echo rows are what
# lands on screen) and refuses to stage anything the old queue could hold.
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
p = os.path.join(rd, "STARTUP.SH")
if not os.path.exists(p):
    sys.exit("vgate_file STARTUP.SH must precede this hook")
rows = []
for ln in open(p, encoding="utf-8").read().splitlines():
    if ln.startswith("echo "):
        rows.append(ln[5:])
sel = "\n".join(rows)
assert len(sel.encode()) > 256, \
    "selection must exceed the old 256 B queue: %d" % len(sel.encode())
assert "\u250c" in sel and "\u4f60" in sel, "selection lost its runes"
for r in rows:
    cells = len(r) + (1 if "\u4f60" in r else 0)
    assert cells <= 79, "row would wrap at 80 cols: %d cells %r" % (cells, r)
shutil.copy(p, os.path.join(share, "STARTUP.SH"))
print("staged STARTUP.SH: %d rows, selection = %d bytes" %
      (len(rows), len(sel.encode())))
# The SESSION.TABS between-run cleanup lives on boot 03's tag-03 assert:
# this hook runs before boot 01, when boots 02/03 have not yet restored
# and re-written the file (the delete here was a no-op).
PY

vgate_file script-04a.txt <<'EOF'
set GOMAXPROCS=1
exec NOTE.ELF
echo m73z-stage1
EOF

# script-04b fires 2 s after `charmhello: size 64x23` (the `r`
# resize, M73j's owner seam): tty counters read after the
# clear+redraw burst (c), the registry dump (geometry evidence), then
# the lower for (e) — last, so the capture happens after it.
vgate_file script-04b.txt <<'EOF'
tty
dui
dui lower 4
EOF

# script-04c fires at `goterm: prompt`: CHARMHELLO must be ON the strip
# before the 16-tick single-tab countdown closes GOTERM (observed r7:
# `host close id=3` mid-drag). Its declare makes n==2 — the countdown
# only runs at n==1 — and arms the two-tab choreography whose
# hidChordHold=32 (raised from 20 for M73z) gives the chain grace past
# its expect: first destructive step = n==2 + hold + 7 steps ~ tick 68,
# with maxTicks 90 (seat.go) bounding the boot above both.
vgate_file script-04c.txt <<'EOF'
exec CHARMHELLO.ELF
EOF

vgate_run 04 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-04' \
    --screenshot-after 'dui lower: lowered=4' \
    --script '$RUN_DIR/script-04a.txt' \
    --script-after 'user-el0 reaped' \
    --input-string $'\nterm\n' \
    --input-string-after 'gotabwm: tab close id=' \
    --pointer-virtio '100,11,c;4,28,d;636,84;636,84,u' \
    --pointer-virtio-after 'charmhello: ready' \
    --input-chords 'ctrl-shift-c,ctrl-shift-v,return,alt-tab' \
    --input-chords-after 'dui: term sel end' \
    --input-key 15 \
    --input-key-after 'gotabwm: alt-tab id=4' \
    --script2 '$RUN_DIR/script-04b.txt' \
    --script2-after 'charmhello: size 64x23' --script2-delay 2 \
    --script3 '$RUN_DIR/script-04c.txt' \
    --script3-after 'goterm: prompt' \
    --script-expect 'dui lower: lowered=4' --timeout 300

vgate_assert 04 share-contains APPS.TXT 'GOTERM.ELF | Terminal | t | dock=true'
vgate_assert 04 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 04 serial-contains 'dogfood: seat'

# --- M82a (#1768): the manifest the launcher read, and what it read --------
# The share's APPS.TXT is the versioned schema, byte for byte: the four v1
# positional fields first, then the v2 tail. GOTERM's own row above is
# deliberately still v1 (four fields, no `v=`) — a row that declares no
# trailing field must be able to stay one, and this is that pin. NOTE's row
# is the v2 shape.
vgate_assert 04 share-contains APPS.TXT 'NOTE.ELF | Text Editor | n | dock=true | v=2 | opens=text'
vgate_assert 04 share-contains APPS.TXT 'WEB.ELF | Web | w | dock=true | v=2 | caps=net | opens=http,https'
# The seat's own decode receipt, printed by the launcher as it parses
# (apps.go SummarizeApps): every row of the share's manifest, the highest
# row version the file declares, this build's schema, and how many rows
# spoke each trailing key. A parser that skipped the tail would still print
# `launcher open n=` and would report v=0 here. The row count is derived
# from the staged APPS.TXT, not a literal -- a literal went stale the day
# image/apps.txt gained a row (observed: n=15 pinned while the file held 20).
vgate_assert 04 python <<'PY'
import os, re, sys
share = os.environ["VG_SHARE"]
rows = [l for l in open(os.path.join(share, "APPS.TXT"), errors="replace")
        if re.match(r"^[A-Z]", l)]
want = "gotabwm: apps decode n=%d v=2 schema=2" % len(rows)
ser = open(os.environ["VG_SER"], errors="replace").read()
if want not in ser:
    m = re.search(r"gotabwm: apps decode .*", ser)
    sys.exit("want %r in serial, saw %r"
             % (want, m.group(0) if m else "absent"))
print("apps decode receipt matches the share manifest: %d rows" % len(rows))
PY

# --- (a) the docked Terminal entry opens through the launcher ---------------
# The seat's own 16-tick choreography emptied the strip first; without it
# Enter lands in the focused app's tty instead of summoning.
vgate_assert 04 serial-contains 'gotabwm: tab close id='
vgate_assert 04 serial-contains 'launcher open n='
vgate_assert 04 serial-contains 'launcher filter q=term n=1'
vgate_assert 04 serial-contains 'launcher exec GOTERM.ELF'
# `exec: loaded GOTERM.ELF` is deliberately not asserted: that line is
# the SHELL exec builtin's (script-04a's NOTE prints it) and the launcher
# execs directly — GOTERM's own open/ready/prompt markers carry the load
# proof below. Observed r7: the line is absent on exactly this path.
vgate_assert 04 serial-contains 'goterm: open id='
vgate_assert 04 serial-contains 'goterm: attached'
vgate_assert 04 serial-contains 'goterm: ready'
vgate_assert 04 serial-contains 'goterm: prompt'

# --- (b) the staged rows selected, copied, pasted, and ran ------------------
# begin+end: both markers of the FORWARDED selection (#1688) — end alone
# could not distinguish a forward from a stray release.
vgate_assert 04 serial-contains 'dui: term sel begin'
vgate_assert 04 serial-contains 'dui: term sel end'
# the pointer phase's FIRST step (right after `charmhello: ready`) is a
# rail click: it pulls focus off charmhello (whose declare steals it)
# AND raises GOTERM above charmhello's fullscreen face — without the
# raise, terminalHitAt resolves the press to charmhello and M73i's
# ?1000 capture reports it instead of selecting (observed serial-04:
# press forwarded, zero sel markers, `tty: paste 0 bytes`). id=3 is
# GOTERM's reused slot.
vgate_assert 04 serial-contains 'gotabwm: rail-click id=3'
# the SEAT's alt-tab flipped focus 3 -> 4 (under a live seat
# input.zig never sets alt_tab_pending: serial-04's `dui:
# alt-tab` was the shim, post-seat-death). Strip = {3,4}: next = 4.
# --input-key 15 waits on THIS marker, so `r`'s kernel delivery
# sees focus=4 — the drain-race fix above.
vgate_assert 04 serial-contains 'gotabwm: alt-tab id=4'
vgate_assert 04 serial-contains 'tty: paste '
# startup lines run silently (no marker), so this `clear` line can only
# have come from the PASTE — M73e's write-back, proven.
vgate_assert 04 serial-contains 'goterm: line clear'
vgate_assert 04 serial-contains 'goterm: done status=0'

# --- (d) the resize seam: new cells + repaint -------------------------------
# M73j's owner seam (`r` via --input-key -> vi.WinResize(512,384)):
# baseline is
# the seat's host-view fullscreen grid, post is the self-resized grid.
# `dui kresize` is deliberately NOT used: it moves the rect without
# notifying the owner (no WIN_RESIZE — observed serial-04), so no size
# marker can ever follow it.
vgate_assert 04 serial-contains 'exec: loaded CHARMHELLO.ELF'
vgate_assert 04 serial-contains 'charmhello: open id='
vgate_assert 04 serial-contains 'charmhello: ready'
vgate_assert 04 serial-contains 'charmhello: size 80x44'
vgate_assert 04 serial-contains 'charmhello: size 64x23'
vgate_assert 04 serial-contains 'dui lower: lowered=4'
vgate_assert 04 serial-contains 'charmhello: repainted'
vgate_assert 04 serial-absent 'keyboard resize failed'

# Two tabs on the one strip: the docked Terminal and charmhello (the hosting
# count idiom boot 01 uses; without it one hosted app could pass every marker
# above).
vgate_assert 04 serial-count 'gotabwm: tab open id=' 2
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

# THE acceptance chain, in order, with the three cross-card pins:
#  (b) the paste carries >256 B INCLUDING row2's 12 rune bytes (floor
#      270: the serial console cannot emit wide glyphs at all —
#      observed serial-04: ZERO occurrences of the box rune in the
#      whole log — so the glyph proof is (e)'s pixels, not a
#      line-echo marker) and every staged row reached the editor
#      (startup lines are silent, so each of these markers can only
#      be the paste);
#  (c) the tty line reads out_dropped=0 in_dropped=0 AFTER the burst
#      (M73f-1's polarity plus M73f-2's line plus a repaint that happened);
#  (d) charmhello's post-resize size marker is EXACTLY its M73j-pinned
#      grid for a 512x384 rect (512/8 = 64 cols, (384-16)/16 = 23 rows
#      — main_test.go pins the formula) after the 80x44 baseline, and
#      the repaint marker follows it.
vgate_assert 04 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()

def at(sub, start=0):
    i = ser.find(sub, start)
    if i < 0:
        sys.exit("missing %r (after %d)" % (sub, start))
    return i

# The chain, each link found AFTER the previous one. The string phase
# fires on NOTE's tab close (the 16-tick hostTicks choreography that
# empties the strip); stage1 prints before NOTE even declares and present
# lands on the first composite tick, so the close — 16 ticks after that
# declare — is strictly after both.
i_seat = at("dogfood: seat")
i_stage = at("m73z-stage1", i_seat)
i_present = at("gotabwm: present", i_seat)
i_close = at("gotabwm: tab close id=", max(i_stage, i_present))
i_open = at("launcher open n=", i_close)
# GOTERM's own host-view proposal (fullscreen) — the origin the drag
# coords and (e) assume. NOTE's identical marker sits before i_close,
# so searching from i_open pins GOTERM's.
i_hv = at("gotabwm: host view id=", i_open)
i_prompt = at("goterm: prompt", i_open)
# The pointer phase runs only after charmhello's declare (its
# fullscreen face would otherwise eat the press — mouse capture),
# rail click FIRST (focus+raise GOTERM), then the drag: press -> sel
# begin, release -> sel end; then copy/paste/return/alt-tab/r.
i_ready = at("charmhello: ready", i_prompt)
i_rail = at("gotabwm: rail-click id=", i_ready)
i_sel = at("dui: term sel end", i_rail)
i_paste = at("tty: paste ", i_sel)

# (b): paste bytes, all staged rows submitted, rune row byte-intact.
m = re.search(r"tty: paste (\d+) bytes", ser)
n = int(m.group(1))
if n <= 256:
    sys.exit("paste must exceed the old 256 B queue (got %d)" % n)
# Row 2 (echo + box-drawing + wide rune + p-run) contributes 12 rune
# bytes: an ASCII-only copy of the five rows tops out near 265, so a
# floor of 270 pins that the rune bytes travelled. The serial console
# cannot PRINT wide glyphs (observed serial-04: zero box runes in the
# entire log), so the pixel proof of the glyphs is (e)'s snapshot.
if n < 270:
    sys.exit("paste lost the rune bytes (got %d, want >= 270)" % n)
i_clear = at("goterm: line clear", i_paste)
# Row 4's ASCII line-echo: the LAST staged row reached the editor (the
# row-2 marker prints without its wide glyphs — serial limitation —
# so the chain anchors on ASCII rows only).
i_lastrow = at("goterm: line echo ccc", i_clear)
n_lines = ser.count("goterm: line ", i_paste)
if n_lines < 5:
    sys.exit("only %d staged rows reached the editor (want all 5)" % n_lines)
i_done = at("goterm: done status=0", i_lastrow)

# The seat's alt-tab flipped focus to charmhello, whose `r` handler
# printed the new grid — script2 gates on THAT marker, so its `tty`
# line lands after both the burst and the resize.
i_alttab = at("gotabwm: alt-tab id=", i_done)
i_rsize = at("charmhello: size 64x23", i_alttab)
i_repaint = at("charmhello: repainted", i_rsize)

# (c): the tty counters, read by script2 (2 s after size 64x23), land
# AFTER the burst and read 0/0.
mtty = re.search(r"tty\[\d+\]: out_dropped=(\d+) in_dropped=(\d+)", ser[i_rsize:])
if not mtty:
    sys.exit("tty drop-counter line missing after the burst")
i_tty = i_rsize + mtty.start()
i_lower = at("dui lower: lowered=", i_tty)
if mtty.group(1) != "0" or mtty.group(2) != "0":
    sys.exit("drop counters must read 0/0 (got %r)" % mtty.group(0))

# (d): size relation — baseline = the LAST `charmhello: size` before
# the `r` resize (tabapp.Init's declare is synchronous with the
# seat's host-view — NOTE's `host view` prints before its `open`, r7
# serial — so the startup marker reads the fullscreen 1280x720 grid as
# 80x44 through M73l's class-A clamp cols=clamp(w/8,8,80); a queued
# duplicate of the same grid may follow), post = the M73j-pinned grid
# of the self-resized 512x384 rect (64x23), and i_repaint-after-i_rsize
# is the repaint that pairs with it (size and repaint print back-to-back
# after the app's one-tick Sleep).
sizes = [(m.start(), int(m.group(1)), int(m.group(2)))
         for m in re.finditer(r"charmhello: size (\d+)x(\d+)", ser)]
before = [s for s in sizes if s[0] < i_rsize]
if not before:
    sys.exit("no pre-resize charmhello: size marker")
_, c0, r0 = before[-1]
pr = re.match(r"charmhello: size (\d+)x(\d+)", ser[i_rsize:])
c1, r1 = int(pr.group(1)), int(pr.group(2))
if (c0, r0) != (80, 44):
    sys.exit("baseline grid %dx%d want 80x44 (host-view fullscreen)"
             % (c0, r0))
if (c1, r1) != (64, 23):
    sys.exit("resize cells %dx%d want 64x23 (r key: 512x384)"
             % (c1, r1))

print("acceptance chain OK: seat@%d stage@%d present@%d close@%d "
      "launcher@%d prompt@%d ready@%d rail@%d sel@%d paste=%dB "
      "lines=%d clear@%d lastrow@%d done@%d alt@%d rsize@%d "
      "%s@%d lower@%d repaint@%d size %dx%d -> %dx%d"
      % (i_seat, i_stage, i_present, i_close, i_open, i_prompt,
         i_ready, i_rail, i_sel, n, n_lines, i_clear, i_lastrow, i_done,
         i_alttab, i_rsize, mtty.group(0).split(":")[0], i_tty,
         i_lower, i_repaint, c0, r0, c1, r1))
PY

# --- (e) THE pixel proof: the pasted line's cells at the END of the run ------
# The pasted `clear` wiped the screen and the pasted rune row re-printed at
# row 0. Charmhello full-screen-declares like every rail app (boot 03's
# passing green pin at y17..29 is the z-order evidence: a focused
# fullscreen declare sits on top of the id2 demo window), so script2's
# `dui lower 4` — z-order only — drops it BEHIND GOTERM; script2 runs ON
# `charmhello: size 64x23` (the `r` resize, which prints size+repaint
# first), so `dui lower: lowered=4` is strictly AFTER both — the
# screenshot/expect barrier. Charmhello also repaints on its host-view
# resize at startup, so `repainted` alone (or a startup size marker)
# would end the run before the paste.
# GOTERM declares full-viewport (kind 8) and the kernel draws a window
# terminal's grid from its 16-row title band, so the row's first 80 cells
# sit at device y16..31, x from 0 (the geometry boot 03's prompt pin
# proved for the same seat shape). The row is
#   [box \u250c\u2500\u2510 cells 0..2][wide \u4f60 cells 3..4][space cell 5][p... cell 6+]
# so: ink in the box span, ink across BOTH cells of the wide rune's pair, a
# BLANK cell where the wide rune's continuation must leave off, ink resuming
# at the exact next cell boundary, and NOTHING at or past col 79 (x>=640) —
# the alignment that fails if the wide rune ever consumed 1 cell (the gap
# would land at [32..40) and p's would start at x40, tripping the blank-cell
# and the past-wall pins at once). script3's `dui` dump records every window
# rect as geometry evidence; if another window ever covered this band the
# pins would fail rather than pass on someone else's pixels.
vgate_assert 04 snapshot 'screen-04-after' <<'PY'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
pos = 8; idat = b''; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b'IHDR':
        w, h, bd, ct = struct.unpack('>IIBB', data[:10])
    elif typ == b'IDAT':
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

def green(x0, x1, y0, y1):
    n = 0
    for y in range(int(y0), int(y1)):
        for x in range(int(x0), int(x1)):
            r, g, b = px(x, y)
            if g > r + 30 and g > b + 30:
                n += 1
    return n

scale = w / 1280.0
y0, y1 = 16 * scale, 32 * scale          # grid row 0 (16-row title band)
def X(dev): return dev * scale
box    = green(X(0),   X(24), y0, y1)    # \u250c \u2500 \u2510, cells 0..2
rune   = green(X(24),  X(40), y0, y1)    # \u4f60 across BOTH pair cells 3..4
gap    = green(X(40),  X(48), y0, y1)    # cell 5 = the space after the rune
pfield = green(X(48),  X(640), y0, y1)   # the P-run, cells 6..79
past   = green(X(640), X(1280), y0, y1)  # col 79's wall and beyond
print("cells: box=%d rune=%d gap=%d pfield=%d past-wall=%d (png %dx%d)"
      % (box, rune, gap, pfield, past, w, h))
assert box >= 20, "box-drawing cells absent (got %d green px)" % box
assert rune >= 30, "wide rune did not paint its cell pair (got %d)" % rune
assert gap <= 10, "cell after the wide rune must be blank (got %d)" % gap
assert pfield >= 100, "the P-run after col 6 is absent (got %d)" % pfield
assert past <= 20, "ink past col 79: the grid shifted (got %d)" % past
print("(e) rune cell rendered, alignment exact, no ink past col 79")
PY

# ---------------------------------------------------------------------------
# M123e (#2579): no serial-only refusals in this boot -- every `rc=-<n>` /
# `refuse[d]` line pairs with a UI-surface marker (rules in refusal-pair.py).
vgate_assert 04 python <<'PY'
import os
exec(compile(open(os.path.join(os.environ["RUN_DIR"], "refusal-pair.py")).read(),
             "refusal-pair.py", "exec"))
PY

# M82d2 (#1785): the notifications center's policy, on the LIVE default seat
# ---------------------------------------------------------------------------
# Boots 01-04 run the seat in DEMO mode (the seeded GOTABWM.DEMO): a bounded
# choreography that auto-closes a lone tab after 16 ticks, far shorter than the
# away-from-keyboard sequence below needs. The policy under test is the
# product's, so these two boots run the seat as a user does -- LIVE, no run
# budget, no auto-close -- by removing the trigger BETWEEN boots 04 and 05.
# That is the same between-run slot boot 03's tag-03 assert uses for
# SESSION.TABS (see above), and the SESSION.TABS goes here too: boot 04's close
# left a session the next boot would re-exec live (M120b), and boot 05 wants
# the first-boot workspace branch (a real GOSH tab), not spawned ghosts.
vgate_assert 04 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE")
if not share:
    sys.exit("no armed share exported to the assert (vgate_share arm?)")
removed = []
for name in ("GOTABWM.DEMO", "SESSION.TABS"):
    p = os.path.join(share, name)
    if os.path.exists(p):
        os.remove(p)
        removed.append(name)
    assert not os.path.exists(p), name + " survived removal"
if "GOTABWM.DEMO" not in removed:
    sys.exit("GOTABWM.DEMO was already gone: the demo trigger's staging changed, "
             "re-check what boots 05/06 run on")
print("between-run cleanup: removed " + ", ".join(removed) +
      " (boots 05/06 run the LIVE seat on a first-boot strip)")
PY

# --- boot 05: notify -> do-not-disturb ON -> notify HELD -> history holds both
# Every stage is caused by a marker the guest printed, never by a delay:
#
#   gotabwm: win focus     script a: `dui focus 0` hands focus away from the
#                          seat's startup probe (boot 01's own first phase).
#   gosh: prompt           script b: GOFILES on the second slot, at the fixture
#                          tree, under `set GOMAXPROCS=1` like every app in boots
#                          01-04. The starter GOSH is tab one.
#   gofiles: ready         --input-string `jjckk\np`: down, down (SOURCE.TXT),
#                          c (copy), up, up (DIR1), Enter (cd DIR1), p (paste)
#                          -> the copy completes -> the app raises a toast.
#                          Printable bytes only (j/k), never arrows: an arrow's
#                          three-byte CSI is not delivered atomically over this
#                          transport (go-wm-seat run 06 measured it).
#   notify paint id=       --pointer-virtio: press the clock panel (the
#                          center's affordance) -> the center OPENS; then press
#                          its header's do-not-disturb control at (770, 195)
#                          = the middle of notifyCenterDNDRect(1280,720) =
#                          (682, 180, 176, 30). Anchored on the PAINT marker so
#                          the toast is provably on the scanout first.
#   notify dnd=on via=seat --input-chords `h,j,l,p`: up to /host/NOTIFY, down
#                          to DIR2, open it, paste -> the SECOND completed copy
#                          raises a SECOND notice. It arrives with DND ON.
#   history write n=2      script c: the tick after the held notice published
#                          the history with both entries. The run then KILLS
#                          the seat (go-wm-seat run 05's ending: a live seat
#                          has no budget), so boot 06 restarts from a seat
#                          that did not get a clean-exit flush -- the file must
#                          already be whole, which is the crash-safe claim.
#
# The chords' letters ride the same virtio keyboard as the string; only the
# anchors differ.
vgate_file script-05a.txt <<'EOF'
dui focus 0
EOF

vgate_file script-05b.txt <<'EOF'
set GOMAXPROCS=1
exec GOFILES.ELF /host/NOTIFY
EOF

vgate_file script-05c.txt <<'EOF'
kill GOTABWM.ELF
echo rx-dogfood-05-ok
EOF

vgate_run 05 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-05' \
    --script '$RUN_DIR/script-05a.txt' \
    --script-after 'gotabwm: win focus' \
    --script2 '$RUN_DIR/script-05b.txt' \
    --script2-after 'gosh: prompt' \
    --input-string $'jjckk\np' \
    --input-string-after 'gofiles: ready' \
    --pointer-virtio '1198,702,d;1198,702,u;770,195,d;770,195,u' \
    --pointer-virtio-after 'gotabwm: notify paint id=' \
    --input-chords 'h,j,l,p' \
    --input-chords-after 'gotabwm: notify dnd=on via=seat' \
    --script3 '$RUN_DIR/script-05c.txt' \
    --script3-after 'gotabwm: notify history write n=2' \
    --script-expect 'rx-dogfood-05-ok' --timeout 420

# The LIVE default seat: the demo trigger is gone and nothing named a seat.
vgate_assert 05 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 05 serial-contains 'gotabwm: mode live'
vgate_assert 05 serial-absent 'gotabwm: mode demo'
vgate_assert 05 serial-contains 'gotabwm: first-boot workspace'
vgate_assert 05 serial-contains 'gosh: prompt'
vgate_assert 05 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 05 serial-contains 'gofiles: declare accepted'
# The sender's half: both copies completed, and the notice sent under DND was
# ACKED (`notify sent`): the seat still answers, so the app cannot tell the
# user is away. The python below pins that ack to the second notice; the first
# notice's ack is not asserted here, because the seat is starved for ~10 s
# right after the first paste (three Go runtimes on two CPUs: no `gotabwm: tick`
# between the paste and the seat's answer, observed on both runs of this
# boot), so GOFILES's 8-tick ack wait can expire and print `notify refused`
# for a notice the seat then queues and paints. The seat's own `notify id=` /
# `notify paint id=` lines are what prove that first notice was accepted.
vgate_assert 05 serial-contains 'gofiles: cd /host/NOTIFY/DIR1'
vgate_assert 05 serial-contains 'gofiles: cd /host/NOTIFY/DIR2'
vgate_assert 05 serial-count 'gofiles: pasted SOURCE.TXT' 2
vgate_assert 05 serial-contains 'gofiles: notify sent copied SOURCE.TXT'
# The seat's half.
vgate_assert 05 serial-contains 'gotabwm: notify id='
vgate_assert 05 serial-contains 'gotabwm: notify paint id='
vgate_assert 05 serial-contains 'gotabwm: notify center open'
vgate_assert 05 serial-contains 'gotabwm: notify dnd=on via=seat persisted=1'
vgate_assert 05 serial-contains 'gotabwm: notify held id='
vgate_assert 05 serial-contains 'gotabwm: notify history write n=1'
vgate_assert 05 serial-contains 'gotabwm: notify history write n=2'
vgate_assert 05 serial-absent 'gotabwm: notify history write fail'
vgate_assert 05 serial-absent 'gotabwm: notify history bad'
# The toggle is the SEAT's, persisted through the settings file...
vgate_assert 05 share-contains SETTINGS.TXT 'notify_dnd=on'
# ...and it is not a `wm` override: the default seat is still the compiled one.
vgate_assert 05 serial-absent 'wm: autostart tabwm'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
vgate_assert 05 serial-contains 'rx-dogfood-05-ok'

# The chain as an ORDERING check, and the "not shown" half: exactly ONE toast
# was ever queued and painted (the one before DND), the second notice reached
# the seat AFTER DND was on and was held, and the held line names the same
# sender the toast did.
vgate_assert 05 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def all_at(pat):
    return [m for m in re.finditer(pat, ser, re.M)]

def one(pat, what):
    ms = all_at(pat)
    if len(ms) != 1:
        sys.exit("want exactly one %s, found %d (%s)" % (what, len(ms), pat))
    return ms[0]

pasted = all_at(r"gofiles: pasted SOURCE\.TXT$")
if len(pasted) != 2:
    sys.exit("want two completed copies, saw %d" % len(pasted))
queued = all_at(r"gotabwm: notify id=(\d+) copied SOURCE\.TXT$")
if len(queued) != 1:
    sys.exit("want exactly ONE queued toast (the one before DND), saw %d: a held "
             "notice must not be queued" % len(queued))
painted = all_at(r"gotabwm: notify paint id=(\d+)$")
if len(painted) != 1:
    sys.exit("want exactly ONE toast painted, saw %d: the held notice was shown" % len(painted))
dnd = one(r"gotabwm: notify dnd=on via=seat persisted=1$", "DND-on transition")
held = all_at(r"gotabwm: notify held id=(\d+) copied SOURCE\.TXT$")
if len(held) != 1:
    sys.exit("want exactly one held notice, saw %d" % len(held))
w1 = one(r"gotabwm: notify history write n=1$", "one-entry publish")
w2 = one(r"gotabwm: notify history write n=2$", "two-entry publish")
outcomes = sorted(
    [(m.start(), "sent") for m in all_at(r"gofiles: notify sent copied SOURCE\.TXT$")] +
    [(m.start(), "refused") for m in all_at(r"gofiles: notify refused copied SOURCE\.TXT$")])
if len(outcomes) != 2:
    sys.exit("want one app-side ack outcome per copy, saw %r" % outcomes)

order = [
    ("first copy", pasted[0].start()),
    ("toast queued", queued[0].start()),
    ("toast painted", painted[0].start()),
    ("DND on", dnd.start()),
    ("second copy", pasted[1].start()),
    ("notice held", held[0].start()),
    ("two-entry publish", w2.start()),
]
if [n for n, _ in order] != [n for n, _ in sorted(order, key=lambda p: p[1])]:
    sys.exit("notify/DND chain out of order: " + repr(order))
# The one-entry publish belongs to the toast, so it precedes DND.
if not (queued[0].start() < w1.start() < dnd.start()):
    sys.exit("the one-entry publish is not between the toast and DND-on")
# The second notice was held and yet ACKED, and the ack answers the seat's
# decision (never before it). Only the first notice's outcome is allowed to be
# a timeout (see the assertions above).
if outcomes[1][1] != "sent":
    sys.exit("the notice sent under DND was not acked: the app saw a refusal")
if not held[0].start() < outcomes[1][0]:
    sys.exit("the app's second ack came before the seat's hold")
# One sender throughout.
if not (queued[0].group(1) == painted[0].group(1) == held[0].group(1)):
    sys.exit("sender ids differ: toast %s, paint %s, held %s"
             % (queued[0].group(1), painted[0].group(1), held[0].group(1)))
# After DND-on, nothing was queued or painted.
tail = ser[dnd.start():]
if re.search(r"gotabwm: notify (id=|paint id=)", tail, re.M):
    sys.exit("a toast was queued or painted after DND was turned on")
print("M82d2 chain OK: toast (id=%s) -> center open -> DND on -> second notice HELD "
      "(id=%s, acked, never painted) -> history published n=1 then n=2"
      % (queued[0].group(1), held[0].group(1)))
PY

# What is on the share, decoded on the HOST by an independent reader of the
# documented layout ("VNH\x01", a count byte, length-framed (source, text)
# records, FNV-1a 32 trailer): a valid two-entry history whose entries are the
# two notices -- the held one included -- and no temp left behind. The bytes
# are also kept for boot 06, which must leave them untouched.
vgate_assert 05 python <<'PY'
import os, shutil, sys
share = os.environ["VG_SHARE"]
rd = os.environ["RUN_DIR"]
path = os.path.join(share, "NOTIFY.HIST")
if not os.path.exists(path):
    sys.exit("no NOTIFY.HIST on the share")
if os.path.exists(path + "~"):
    sys.exit("NOTIFY.HIST~ survived the publish - the rename did not run")
raw = open(path, "rb").read()

def fnv(b):
    h = 2166136261
    for c in b:
        h ^= c
        h = (h * 16777619) & 0xffffffff
    return h

if raw[:4] != b"VNH\x01":
    sys.exit("bad magic %r" % raw[:4])
body, tail = raw[:-4], raw[-4:]
if fnv(body) != int.from_bytes(tail, "little"):
    sys.exit("checksum does not match the body")
n = body[4]
off = 5
recs = []
for _ in range(n):
    sl, tl = body[off], body[off + 1]
    off += 2
    recs.append((body[off:off + sl], body[off + sl:off + sl + tl]))
    off += sl + tl
if off != len(body):
    sys.exit("%d stray bytes after the last record" % (len(body) - off))
if n != 2 or any(t != b"copied SOURCE.TXT" for _, t in recs):
    sys.exit("history holds %r, want the two copied-SOURCE.TXT notices" % recs)
shutil.copy(path, os.path.join(rd, "notify-hist-05.bin"))
print("NOTIFY.HIST on the share: %d bytes, %d valid entries (%s), no temp left"
      % (len(raw), n, ", ".join(repr(t.decode()) for _, t in recs)))
PY

# M123e (#2579): no serial-only refusals in this boot -- every `rc=-<n>` /
# `refuse[d]` line pairs with a UI-surface marker (rules in refusal-pair.py).
vgate_assert 05 python <<'PY'
import os
exec(compile(open(os.path.join(os.environ["RUN_DIR"], "refusal-pair.py")).read(),
             "refusal-pair.py", "exec"))
PY

# --- boot 06: restart -> DND still on, both notices still there ---------------
# A fresh VM on the same share. The seat that left was killed, not asked to
# exit, so everything below survived on the strength of the crash-safe publish.
#
#   gotabwm: win focus     script a: `dui focus 0`, as in every boot here.
#   gotabwm: win gone      --pointer-virtio: press the clock panel -> the center
#                          OPENS with the restored history; the snapshot fires
#                          when it is PRESENTED (`notify center paint`); a later
#                          press on the header control turns DND back OFF, so
#                          the toggle's persistence is proven both directions.
#   dnd=off via=seat       script b: kill the seat, then the run's end marker.
vgate_file script-06a.txt <<'EOF'
dui focus 0
EOF

vgate_file script-06b.txt <<'EOF'
kill GOTABWM.ELF
echo rx-dogfood-06-ok
EOF

vgate_run 06 -- \
    --via-virtio --cvc-snap \
    --screen '$RUN_DIR/screen-06' \
    --snapshot-after 'gotabwm: notify center paint' \
    --snapshot-out '$RUN_DIR/snap-06' \
    --script '$RUN_DIR/script-06a.txt' \
    --script-after 'gotabwm: win focus' \
    --pointer-virtio '1198,702,d;1198,702,u;770,195,d;770,195,u' \
    --pointer-virtio-after 'gotabwm: win gone' \
    --script2 '$RUN_DIR/script-06b.txt' \
    --script2-after 'gotabwm: notify dnd=off via=seat' \
    --script-expect 'rx-dogfood-06-ok' --timeout 420

vgate_assert 06 serial-contains 'gotabwm: mode live'
vgate_assert 06 serial-absent 'gotabwm: mode demo'
# The choice survived the restart: read from the persisted key before the loop.
vgate_assert 06 serial-contains 'gotabwm: notify dnd=on via=boot'
# And so did both notices: restored from the file boot 05 published.
vgate_assert 06 serial-contains 'gotabwm: notify history restore n=2'
vgate_assert 06 serial-absent 'gotabwm: notify history bad'
vgate_assert 06 serial-absent 'gotabwm: notify history healed'
# The center opened on the restored history, and the seat control turned DND
# off again, persisting it.
vgate_assert 06 serial-contains 'gotabwm: notify center open'
vgate_assert 06 serial-contains 'gotabwm: notify center paint'
vgate_assert 06 serial-contains 'gotabwm: notify dnd=off via=seat persisted=1'
vgate_assert 06 share-contains SETTINGS.TXT 'notify_dnd=off'
# Nothing in this boot changed the history, so the file is boot 05's, byte for
# byte (`notify-hist-05.bin` is the copy boot 05's assert took).
vgate_assert 06 share-equals NOTIFY.HIST notify-hist-05.bin
vgate_assert 06 serial-absent 'gotabwm: notify history write'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'
vgate_assert 06 serial-contains 'rx-dogfood-06-ok'

# Restored BEFORE the first paint: the history load precedes the loop, so its
# line comes before the seat's first tick and first present -- there is no
# frame that showed an empty center which then filled in. DND is read before
# that too, so the first notice this seat ever receives already obeys it.
vgate_assert 06 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
def line_of(prefix):
    for i, l in enumerate(ser):
        if prefix in l:
            return i
    sys.exit("the serial has no %r line" % prefix)
dnd = line_of("gotabwm: notify dnd=on via=boot")
restore = line_of("gotabwm: notify history restore n=2")
mode = line_of("gotabwm: mode live")
tick = line_of("gotabwm: tick")
present = line_of("gotabwm: present")
opened = line_of("gotabwm: notify center open")
off = line_of("gotabwm: notify dnd=off via=seat")
if not (dnd < mode and restore < mode):
    sys.exit("DND (%d) and the restore (%d) must both precede the mode line (%d)"
             % (dnd, restore, mode))
if not (restore < tick and restore < present):
    sys.exit("restore (line %d) did not precede the first tick (%d) / present (%d)"
             % (restore, tick, present))
if not (present < opened < off):
    sys.exit("center open (%d) / DND off (%d) out of order after the first present (%d)"
             % (opened, off, present))
print("boot read DND (line %d) and restored 2 entries (line %d) before the first "
      "tick (%d) and present (%d); center opened at %d, DND turned off at %d"
      % (dnd, restore, tick, present, opened, off))
PY

# THE pixel proof, from the guest's own composed scanout at the moment the
# reopened center was PRESENTED: the panel holds the two restored entries (their
# text in the InkMuted token on rows 0 and 1, nothing on row 2), their sender
# rendered as closed (the Muted token), and the header's do-not-disturb label in
# the Accent -- the mode is readable at a glance. Geometry is
# notifyCenterRect(1280,720) = (380, 180, 520, 360); row i's source line is at
# y = 180+30+34i+2 and its text at +16; the control is at (682, 180, 176, 30).
# Dark palette: Accent 0x3b82f6, Muted 0x94a3b8, InkMuted 0x8b98a5.
vgate_assert 06 snapshot 'snap-06-*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)" % (len(raw), need, W, H))

def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])

def count(color, x0, x1, y0, y1):
    return sum(1 for y in range(y0, y1) for x in range(x0, x1) if px(x, y) == color)

ACCENT = (0x3b, 0x82, 0xf6)
MUTED = (0x94, 0xa3, 0xb8)
INKMUTED = (0x8b, 0x98, 0xa5)
PX, PY, PW, PH = 380, 180, 520, 360
ROW0, ROW = PY + 30, 34

dnd = count(ACCENT, 682, 858, PY + 4, PY + 26)
src0 = count(MUTED, PX + 12, PX + 12 + 48 * 8, ROW0 + 2, ROW0 + 10)
src1 = count(MUTED, PX + 12, PX + 12 + 48 * 8, ROW0 + ROW + 2, ROW0 + ROW + 10)
txt0 = count(INKMUTED, PX + 12, PX + 12 + 48 * 8, ROW0 + 16, ROW0 + 24)
txt1 = count(INKMUTED, PX + 12, PX + 12 + 48 * 8, ROW0 + ROW + 16, ROW0 + ROW + 24)
txt2 = count(INKMUTED, PX + 12, PX + 12 + 48 * 8, ROW0 + 2 * ROW + 16, ROW0 + 2 * ROW + 24)
print("center rows: dnd-accent=%d closed-source=%d/%d text=%d/%d row2-text=%d"
      % (dnd, src0, src1, txt0, txt1, txt2))
assert dnd >= 20, ("only %d accent pixels in the DND control: the label is not in "
                   "the ON colour, or the control did not paint" % dnd)
assert src0 >= 10 and src1 >= 10, ("the restored senders are not rendered as closed "
                                   "(%d/%d muted pixels)" % (src0, src1))
assert txt0 >= 20 and txt1 >= 20, ("the restored notices' text is not on the scanout "
                                   "(%d/%d ink pixels)" % (txt0, txt1))
assert txt2 == 0, ("a third row painted text (%d px): the center holds more than the "
                   "two restored notices" % txt2)
print("the reopened center shows exactly the two restored notices, DND on")
PY

# Between-run cleanup for boot 07, on THIS tag's asserts: boot 07 wants the
# first-boot workspace branch (a real starter GOSH tab to exec from), so a
# SESSION.TABS left by any earlier seat close must not survive into it --
# the same between-run slot boots 03->04 and 04->05 already use.
vgate_assert 06 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE")
if not share:
    sys.exit("no armed share exported to the assert (vgate_share arm?)")
st = os.path.join(share, "SESSION.TABS")
if os.path.exists(st):
    os.remove(st)
    assert not os.path.exists(st), "SESSION.TABS survived removal"
    print("between-run cleanup: removed SESSION.TABS "
          "(boot 07 summons on an empty strip)")
else:
    print("between-run cleanup: no SESSION.TABS to remove "
          "(boot 07 already boots an empty strip)")
PY

# ---------------------------------------------------------------------------
# M123e (#2579): no serial-only refusals in this boot -- every `rc=-<n>` /
# `refuse[d]` line pairs with a UI-surface marker (rules in refusal-pair.py).
vgate_assert 06 python <<'PY'
import os
exec(compile(open(os.path.join(os.environ["RUN_DIR"], "refusal-pair.py")).read(),
             "refusal-pair.py", "exec"))
PY

# M118e (#2483): boot 07 -- GOSOUND's record mode on the default seat
# ---------------------------------------------------------------------------
# `exec GOSOUND.ELF record N out.wav` is the M118e verb: the player becomes a
# recorder, bounded by construction (seconds <= 30, one WriteFileSafe
# publish, the kernel's 64 KiB ring bounding every slot-92 call) with the mic
# meter live in the window while frames land.
#
# This spec runs NO audio device -- no --sound and no --sound-in anywhere on
# the dogfood runner -- so boot 07 pins exactly the two truths the boot can
# prove honestly: the mode EXISTS on the default seat (the verb dispatches,
# the cap report prints) and the device-absent refusal is the named ENXIO
# with no file written -- the same receipt shape GOREC's live-sound-record
# pins on the flag-off side.
#
#   gotabwm: win focus    script a: `dui focus 0`, the phase-1 idiom every
#                         boot here shares.
#   gosh: prompt          script b: the record verb on the starter shell.
#   gosound: rec done     script c: the run's own end marker. `rec done` is
#                         the mode's terminal marker -- it prints on EVERY
#                         path (wrote, refused, stopped), so a refusal can
#                         never stall the run.

vgate_file script-07a.txt <<'EOF'
dui focus 0
EOF

vgate_file script-07b.txt <<'EOF'
set GOMAXPROCS=1
exec GOSOUND.ELF record 1 /host/GOSOUND/dogfood.wav
EOF

vgate_file script-07c.txt <<'EOF'
echo rx-dogfood-07-ok
EOF

vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --script '$RUN_DIR/script-07a.txt' \
    --script-after 'gotabwm: win focus' \
    --script2 '$RUN_DIR/script-07b.txt' \
    --script2-after 'gosh: prompt' \
    --script3 '$RUN_DIR/script-07c.txt' \
    --script3-after 'gosound: rec done' \
    --script-expect 'rx-dogfood-07-ok' --timeout 300

vgate_assert 07 serial-contains 'dogfood: seat'
vgate_assert 07 serial-contains 'gosh: prompt'
vgate_assert 07 serial-contains 'exec: loaded GOSOUND.ELF'
# The mode exists: the verb parsed, the mode marker printed, and a window
# opened on the seat (the meter's canvas -- no frames ever arrive on this
# boot, so the meter's level stays 0 and no `level=` line prints).
vgate_assert 07 serial-contains 'gosound: rec secs=1 out=/host/GOSOUND/dogfood.wav'
vgate_assert 07 serial-contains 'gosound: open id='
# The honest outcome: slot 91 reports no usable capture source and slot 92
# answers ENXIO -- zero frames is a refusal, never a short read.
vgate_assert 07 serial-contains 'gosound: cap ready=0'
vgate_assert 07 serial-contains 'gosound: rec refused ENXIO at=0 of=96000'
vgate_assert 07 serial-contains 'gosound: rec done'
vgate_assert 07 serial-absent 'gosound: rec wrote'
vgate_assert 07 serial-absent 'gosound: rec level='
vgate_assert 07 serial-contains 'rx-dogfood-07-ok'
vgate_assert 07 serial-absent '[EXC] parking'
vgate_assert 07 serial-absent 'exited status=139'

# A refused record leaves nothing behind on the share -- the guest's file
# channel is the second reporter and its silence must agree with serial.
vgate_assert 07 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
p = os.path.join(share, "GOSOUND", "dogfood.wav")
if os.path.exists(p):
    sys.exit("the absent-device refusal left a file behind: " + p)
PY

# The capture leg -- SoundInProbe --sound-in --share: the input stream at
# index 0, the VirtioFS share as exec's app source and the WAV's /host. The
# guest takes 2 s of the v1 tuple in 8192-byte chunks (the meter's tick);
# each landed chunk feeds the level marker and the window's meter. A
# consented host lands a file the host re-verifies byte for byte; a denied
# host prints the bounded ETIMEDOUT and the share stays empty -- never a
# hang, never a truncated WAV. Same two-outcome pin as live-sound-record.
vgate_assert 07 python <<'PY'
import hashlib, os, re, shutil, subprocess, sys

rd = os.environ["RUN_DIR"]
suffix = os.environ.get("VIRELAI_GATE_SUFFIX", "")
probe = os.path.join(os.getcwd(), "host/vm-runner/.build/release/SoundInProbe")
if not os.path.exists(probe):
    sys.exit("SoundInProbe missing at %s (the package swift build precedes the run)" % probe)
codesign = subprocess.run(
    ["codesign", "--force", "--sign", "-", "--entitlements",
     "host/vm-runner/entitlements.plist", probe],
    capture_output=True, text=True)
if codesign.returncode != 0:
    sys.exit("codesign of SoundInProbe failed: %s%s" % (codesign.stdout, codesign.stderr))

share = os.path.join(rd, "gosound-share")
os.makedirs(share, exist_ok=True)
src = os.path.join(".build", "go", "GOSOUND.ELF")
if not os.path.exists(src):
    sys.exit("GOSOUND.ELF missing (expected %s) - build it first: "
             "bash tools/go/build-gosound.sh" % src)
shutil.copy(src, os.path.join(share, "GOSOUND.ELF"))

script = os.path.join(rd, "gosound-rec-script.txt")
with open(script, "w") as fh:
    fh.write("exec GOSOUND.ELF record 2 /host/GOSOUND/clip.wav\n")
serial = os.path.join(rd, "gosound-rec-serial.log")
run = subprocess.run(
    [probe, "--disk", "artifacts/disk.img",
     "--vars", os.path.join(rd, "gosound-rec-vars.bin"),
     "--serial", serial,
     "--sound-in", "--share", share,
     "--script", script,
     "--script-expect", "gosound: rec done",
     "--timeout", "180"],
    capture_output=True, text=True)
with open(os.path.join(rd, "gosound-rec-run.txt"), "w") as fh:
    fh.write(run.stdout + run.stderr)
if os.path.exists(serial):
    shutil.copyfile(serial, "artifacts/go-dogfood-serial-gosound-rec%s.log" % suffix)
if run.returncode != 0:
    sys.exit("SoundInProbe --sound-in --share (GOSOUND record) exited %d:\n%s%s"
             % (run.returncode, run.stdout[-1500:], run.stderr[-1500:]))
text = open(serial, errors="replace").read()

# The guest took the scripted exec and ran to its terminal marker.
for want in ("exec: loaded GOSOUND.ELF", "gosound: rec done"):
    if want not in text:
        sys.exit("guest serial missing %r -- the recorder never finished" % want)
m = re.search(r"gosound: cap ready=(\d+)", text)
if not m or m.group(1) != "1":
    sys.exit("slot 91 did not report the observed INPUT stream "
             "(cap line: %r)" % (m.group(0) if m else "absent"))

clip = os.path.join(share, "GOSOUND", "clip.wav")
wrote = re.search(r"gosound: rec wrote (\S+) seconds=(\d+) frames=(\d+)"
                  r" bytes=(\d+) peak=(\d+) sha256=([0-9a-f]{64})", text)
refused = re.search(r"gosound: rec refused (\w+)", text)

if wrote:
    path, seconds, frames, nbytes, peak, sha = wrote.groups()
    if path != "/host/GOSOUND/clip.wav" or seconds != "2":
        sys.exit("receipt path/seconds wrong: %r" % wrote.group(0))
    if int(frames) != 96000 or int(nbytes) != 192000:
        sys.exit("receipt arithmetic broken: frames=%s bytes=%s"
                 % (frames, nbytes))
    if not os.path.isfile(clip):
        sys.exit("guest reported wrote but the share holds no clip.wav")
    # Lift the evidence before the share is torn down.
    kept = os.path.join(rd, "share-GOSOUND_clip.wav")
    shutil.copyfile(clip, kept)
    shutil.copyfile(kept, "artifacts/go-dogfood-share-GOSOUND_clip%s.wav" % suffix)
    body = open(clip, "rb").read()
    # The whole 44-byte header is determined by the v1 tuple -- byte-compare
    # it, then recompute duration and sha256 off the share, never trusting
    # the receipt for either.
    want_hdr = (
        b"RIFF" + (36 + 192000).to_bytes(4, "little") + b"WAVE"
        + b"fmt " + (16).to_bytes(4, "little")
        + (1).to_bytes(2, "little")      # WAVE_FORMAT_PCM
        + (1).to_bytes(2, "little")      # mono
        + (48000).to_bytes(4, "little")
        + (96000).to_bytes(4, "little")  # byte rate
        + (2).to_bytes(2, "little")      # block align
        + (16).to_bytes(2, "little")     # bits
        + b"data" + (192000).to_bytes(4, "little")
    )
    if len(body) != 44 + 192000 or body[:44] != want_hdr:
        sys.exit("clip.wav is not the expected PCM16/48k/mono RIFF/WAVE: "
                 "len=%d" % len(body))
    data_len = int.from_bytes(body[40:44], "little")
    if data_len % 96000 != 0 or data_len // 96000 != 2:
        sys.exit("recomputed duration is not 2 s: data=%d B" % data_len)
    if hashlib.sha256(body).hexdigest() != sha:
        sys.exit("share file sha256 disagrees with the guest's receipt")
    # The meter really ran: at least one reading reached serial (the first
    # captured chunk always prints its level).
    if "gosound: rec level=" not in text:
        sys.exit("the wrote receipt landed but no meter level ever printed")
    print("record leg: captured=192000 peak=%s sha256=%s verified off the share"
          % (peak, sha))
elif refused:
    name = refused.group(1)
    if name != "ETIMEDOUT":
        sys.exit("capture refused %s, want ETIMEDOUT (or the wrote receipt)"
                 % name)
    if "gosound: rec wrote" in text:
        sys.exit("both refused and wrote markers present")
    if os.path.exists(clip):
        sys.exit("a refused record left a WAV behind")
    if "gosound: rec level=" in text:
        sys.exit("a meter level printed on a refused record -- no frames "
                 "could have landed")
    print("record leg: host mic denied -- bounded ETIMEDOUT, no file (pass shape)")
else:
    sys.exit("no outcome: neither a wrote receipt nor a refused marker")
PY

# Between-run cleanup for boot 08, on THIS tag's asserts: the journey wants
# a restored-EMPTY strip (no starter GOSH) so GOFILES + GOEDIT are the only
# two tabs the split needs — a count=0 v2 file is the same suppression
# boots 01/02 used against M120b's re-exec.
vgate_assert 07 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE")
if not share:
    sys.exit("no armed share exported to the assert (vgate_share arm?)")
st = os.path.join(share, "SESSION.TABS")
open(st, "wb").write(b"\x02\x00\x00\x00\x00\x00")
print("between-run cleanup: empty SESSION.TABS for boot 08 "
      "(restored-empty: no starter, strip starts at 0)")
PY

# ---------------------------------------------------------------------------
# M124f (#2585): boot 08 -- the cross-app data-flow journey, one boot
# ---------------------------------------------------------------------------
# Phase anchors, in fire order (every anchor is a guest-printed marker):
#
#   dogfood: seat        script a: dui focus 0 + GOMAXPROCS + `clip seeded77`
#                        (seeds the kernel clipboard for GOEDIT's ctrl-v) +
#                        exec -u0 GOFILES.ELF /host/FLOW.
#   gofiles: ready       script b: exec -u0 GOEDIT.ELF /host/FLOW/SEL.TXT —
#                        second tab, takes focus on declare.
#   goedit: present      --input-chords: `ctrl-shift-v,ctrl-a,ctrl-v,
#                        ctrl-shift-s,backspace x6,S,A,V,E,D,.,T,X,T,return`.
#                        GOEDIT stays focused through the whole burst:
#                        split v (GOFILES left | GOEDIT right), select-all +
#                        selpub (the M124e publish), paste the seeded 8 B
#                        (M124c read), save-as SAVED.TXT (M124b).
#   gotabwm: split v     --pointer-virtio: the whole gesture half —
#                        drag NOTE.TXT onto GOEDIT's right pane (M124a);
#                        right-click PIC.PNG -> "Open With…" -> GOVIEW.ELF
#                        (M124d — the launched GOVIEW is the copy source);
#                        unpressed hovers cover GOVIEW's boot + 'c' copy +
#                        the GOTERM exec; the last step middle-clicks inside
#                        GOTERM's fullscreen pane (M124e delivery).
#   gview: ready         --input-string 'c' — GOVIEW just declared, so it is
#                        focused; `gview: copy mime=image/png` is the M124c
#                        typed write.
#   gview: copy          script c: exec -u0 GOTERM.ELF — a declare steals
#                        focus and paints fullscreen, so it must land only
#                        after the copy; its tab is the middle-click target.
#   goterm: done status=0  the run's expect AND the snapshot barrier: the
#                        pasted line's ink is on the scanout.
#
# Row/cell geometry: same seat as go-drag — rail 22, hosted window starts
# y=22, SGR row (y-22)/16+1, cell 8x16. GOFILES list rows 0/1 at y=62/78.
# The menu anchors at the right-clicked cell (col5,row3 for a (40,78) rc):
# plate rows 3-4, "Open With…" at row 4 (x in cols 5..17 -> 80,94), the
# submenu at cols 18..31 row 4 (GOVIEW.ELF is the only opens=image row ->
# 148,94).
vgate_file script-08a.txt <<'EOF'
dui focus 0
set GOMAXPROCS=1
clip seeded77
exec -u0 GOFILES.ELF /host/FLOW
EOF

vgate_file script-08b.txt <<'EOF'
exec -u0 GOEDIT.ELF /host/FLOW/SEL.TXT
EOF

vgate_file script-08c.txt <<'EOF'
exec -u0 GOTERM.ELF
EOF

vgate_run 08 -- \
    --via-virtio --cvc-snap \
    --screen '$RUN_DIR/screen-08' \
    --snapshot-out '$RUN_DIR/snap-08' \
    --snapshot-after 'goterm: done status=0' \
    --script '$RUN_DIR/script-08a.txt' \
    --script-after 'dogfood: seat' \
    --script2 '$RUN_DIR/script-08b.txt' \
    --script2-after 'gofiles: ready' \
    --input-chords 'ctrl-shift-v,ctrl-a,ctrl-v,ctrl-shift-s,backspace,backspace,backspace,backspace,backspace,backspace,S,A,V,E,D,.,T,X,T,return,ctrl-2' \
    --input-chords-after 'goedit: present' \
    --pointer-virtio '640,400;640,400;40,62,d;200,200;320,240;480,280;900,360,u;640,400;640,400;100,11,c;640,400;640,400;640,400;640,400;640,400;640,400;640,400;640,400,mc' \
    --pointer-virtio-after 'gotabwm: split v' \
    --input-string 'jo1' \
    --input-string-after 'gotabwm: rail-click' \
    --input-key 8 \
    --input-key-after 'gview: ready' \
    --script3 '$RUN_DIR/script-08c.txt' \
    --script3-after 'gview: copy mime=image/png' \
    --script-expect 'goterm: done status=0' --timeout 420

# The LIVE default seat, restored-empty: no starter, no wm override.
vgate_assert 08 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 08 serial-contains 'gotabwm: mode live'
vgate_assert 08 serial-absent 'gotabwm: mode demo'
vgate_assert 08 serial-absent 'wm: autostart tabwm'
vgate_assert 08 serial-absent 'dogfood: gosh'

# --- the seeded clipboard (script a) and the two tabs -----------------------
vgate_assert 08 serial-contains 'clip: stored 8 bytes'
vgate_assert 08 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 08 serial-contains 'gofiles: declare accepted'
vgate_assert 08 serial-contains 'gofiles: list /host/FLOW n=3'
vgate_assert 08 serial-contains 'gofiles: ready'
vgate_assert 08 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 08 serial-contains 'goedit: read /host/FLOW/SEL.TXT n=17'
vgate_assert 08 serial-contains 'goedit: present'

# --- the chords burst: split, M124e publish, M124c read, M124b save-as ------
vgate_assert 08 serial-contains 'gotabwm: split v'
vgate_assert 08 serial-contains 'x=640 y=0 w=640 h=720'
vgate_assert 08 serial-contains 'goedit: selpub n=17'
vgate_assert 08 serial-contains 'gotabwm: sel pub id='
vgate_assert 08 serial-contains 'goedit: paste n=8'
vgate_assert 08 serial-contains 'goedit: pick save /host/FLOW/'
vgate_assert 08 serial-contains 'goedit: saved /host/FLOW/'
vgate_assert 08 serial-absent 'goedit: pick cancel'
# The picker -> /disk -> visible-in-GOFILES leg: GOFILES' own watch feed
# reported the new entry, and the share holds a new .TXT whose bytes are
# the pasted buffer. The exact name is content-verified, not pinned — a
# single dropped backspace stroke legitimately spells it differently
# (observed SSAVED.TXT) and the pipe is the same.
vgate_assert 08 serial-contains 'gofiles: watch created '
vgate_assert 08 python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
flow = os.path.join(share, "FLOW")
new = [n for n in os.listdir(flow)
       if n not in ("NOTE.TXT", "PIC.PNG", "SEL.TXT")]
if len(new) != 1:
    sys.exit("want exactly one new file in FLOW, got %r" % new)
got = open(os.path.join(flow, new[0]), "rb").read()
if got != b"seeded77":
    sys.exit("saved %r holds %r, want the pasted seeded77" % (new[0], got))
print("save-as verified on the share: %s == seeded77 (%d bytes)"
      % (new[0], len(got)))
PY

# --- M124a: the drag ---------------------------------------------------------
vgate_assert 08 serial-contains 'gofiles: drag arm NOTE.TXT text/plain len=8'
vgate_assert 08 serial-contains 'gotabwm: drag arm id='
vgate_assert 08 serial-contains 'gotabwm: drag over id='
vgate_assert 08 serial-contains 'accept=1'
vgate_assert 08 serial-contains 'gotabwm: drag drop id='
vgate_assert 08 serial-contains ' mime=text/plain'
vgate_assert 08 serial-contains 'goedit: drop text/plain n=8'
vgate_assert 08 serial-contains 'gofiles: drag end delivered win='
vgate_assert 08 serial-absent 'gotabwm: drag refuse'
vgate_assert 08 serial-absent 'gotabwm: drag cancel'
vgate_assert 08 serial-absent 'gofiles: drag refused'

# --- M124d: Open With -> GOVIEW.ELF (the 'o' handler list) -------------------
# candidates=2 is the registry's truth for type=image: mime.init registers
# GOVIEW first and GOEDIT second ("Code Editor (raw bytes)", the fallback for
# the formats GOVIEW has no decoder for) — go-fileman run 02 pins the same
# count for PIC.QOI. A candidates=1 pin was this spec's own bug.
vgate_assert 08 serial-contains 'gofiles: open with PIC.PNG type=image candidates=2'
vgate_assert 08 serial-contains 'gofiles: open chose PIC.PNG type=image handler=GOVIEW.ELF'
vgate_assert 08 serial-contains 'gofiles: open launched PIC.PNG handler=GOVIEW.ELF pid='
vgate_assert 08 serial-absent 'gofiles: open launch refused'
vgate_assert 08 serial-contains 'gview: loaded PIC.PNG 160x120'
vgate_assert 08 serial-contains 'gview: ready'

# --- M124c: the typed write --------------------------------------------------
vgate_assert 08 serial-contains 'gview: copy mime=image/png n=420'
vgate_assert 08 serial-absent 'gview: copy refuse'

# --- M124e: publish -> middle-click -> GOTERM consumes -----------------------
vgate_assert 08 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 08 serial-contains 'goterm: ready'
vgate_assert 08 serial-contains 'gotabwm: sel paste id='
vgate_assert 08 serial-contains 'goterm: sel-paste n=17'
vgate_assert 08 serial-contains 'goterm: line echo sel-live-ok'
vgate_assert 08 serial-contains 'goterm: done status=0'
# Four tabs on the one strip over the boot: GOFILES, GOEDIT, GOVIEW, GOTERM.
vgate_assert 08 serial-count 'gotabwm: tab open id=' 4
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-absent 'exited status=139'

# The journey as ONE ordered chain — each marker located strictly after the
# one before it, so no leg can pass on a stale or reordered log.
vgate_assert 08 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
def at(sub, start=0):
    i = ser.find(sub, start)
    if i < 0:
        sys.exit("missing %r (after %d)" % (sub, start))
    return i
i_seat = at("dogfood: seat")
i_clip = at("clip: stored 8 bytes", i_seat)
i_gf = at("gofiles: ready", i_clip)
i_ge = at("goedit: read /host/FLOW/SEL.TXT n=17", i_gf)
i_present = at("goedit: present", i_ge)
i_split = at("gotabwm: split v", i_present)
# App-vs-seat serial positions are NOT contract-pinned: each side drains
# its own queue on its own M, so whichever is faster wins the byte race
# (the M121e rule -- "the seat's mirror is processed after delivery";
# on a loaded host `drag arm` was observed ahead of `saved`). What IS
# pinned: goedit's chord answers queue in batch order (selpub -> paste ->
# saved), the seat's `sel pub` RPC cannot predate the batch that sent it,
# and the pointer script is phase-armed on `split v` so every drag/rail
# marker follows it in the seat's own stream order.
i_selpub = at("goedit: selpub n=17", i_present)
i_paste = at("goedit: paste n=8", i_selpub)
i_save = at("goedit: saved /host/FLOW/", i_paste)
i_pub = at("gotabwm: sel pub id=", i_present)
i_arm = at("gotabwm: drag arm id=", i_split)
i_ddrop = at("gotabwm: drag drop id=", i_arm)
i_rclick = at("gotabwm: rail-click", i_ddrop)
# The drop's Seq=0 notice posts BEFORE the seat's `drag drop` marker and
# the source's Seq=1 receipt posts AFTER it (drag.go), so goedit's answer
# anchors on the arm and gofiles' receipt anchors on the drop marker.
i_drop = at("goedit: drop text/plain n=8", i_arm)
i_rcpt = at("gofiles: drag end delivered", i_ddrop)
i_menu = at("gofiles: open with PIC.PNG", i_rclick)
i_launch = at("gofiles: open launched PIC.PNG handler=GOVIEW.ELF", i_menu)
i_gv = at("gview: ready", i_launch)
i_copy = at("gview: copy mime=image/png", i_gv)
i_term = at("goterm: ready", i_copy)
i_sp = at("goterm: sel-paste n=17", i_term)
i_echo = at("goterm: line echo sel-live-ok", i_sp)
i_done = at("goterm: done status=0", i_echo)
i_watch = at("gofiles: watch created ", i_save)
print("M124f journey chain OK: seat -> clip-seed -> gofiles -> goedit -> "
      "split | app lane: selpub -> paste -> saved | seat lane: sel-pub "
      "-> drag-arm -> drop -> rail-click | goedit drop@%d gofiles "
      "delivered@%d | openwith -> launched -> gview -> copy -> goterm -> "
      "sel-paste -> echo -> done (watch@%d)" % (i_drop, i_rcpt, i_watch))
PY

# THE pixel proof: GOTERM's own scanout at the moment the pasted command
# finished — the terminal's green text (the echoed line and its output)
# painted real ink in the window's first grid rows. Same palette rule as
# boot 03's pin: count only GREEN-dominant pixels so a painted ghost or
# plate cannot pass by accident. BGRX raw, 1280x720.
vgate_assert 08 snapshot 'snap-08-*.raw' <<'PY'
import sys
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))
def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])
green = 0
for y in range(16, 112):
    for x in range(0, 640):
        r, g, b = px(x, y)
        if g > r + 30 and g > b + 30:
            green += 1
print("terminal-green pixels in GOTERM's first grid rows: %d" % green)
assert green >= 50, ("the pasted line painted no terminal ink (%d green px) "
                     "- the sel-paste->echo chain is not on the scanout" % green)
PY

# Boot 09 wants boot 08's own start state: a restored-empty strip. The
# M124f journey ends its boot with {GOFILES,GOEDIT,GOVIEW,GOTERM} written
# to SESSION.TABS, and an M120b restore of those rows would re-exec four
# clients before the first phase -- so the same tag-level cleanup boot 07
# ran for boot 08 runs here for boot 09.
vgate_assert 08 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE")
if not share:
    sys.exit("no armed share exported to the assert (vgate_share arm?)")
open(os.path.join(share, "SESSION.TABS"), "wb").write(b"\x02\x00\x00\x00\x00\x00")
print("between-run cleanup: empty SESSION.TABS for boot 09 "
      "(restored-empty: no starter, strip starts at 0)")
PY

# ---------------------------------------------------------------------------
# M121f (#2569): boot 09 -- the keyboard-only daily-driver journey, one boot
# ---------------------------------------------------------------------------
# The arc's acceptance: every surface the M121 cards landed, driven the way a
# user drives it -- by keyboard alone. No pointer phase is armed at all
# (there is no --pointer-virtio on this run), and the serial is pinned free
# of the pointer-produced markers so a pointer path could not have leaked
# in to help a leg pass.
#
# Phase anchors, in fire order (every anchor is a guest-printed marker):
#
#   dogfood: seat        script a: `dui focus 0` hands focus off the seat's
#                        startup probe, GOMAXPROCS=1 like every app in this
#                        spec, exec GOTERM.ELF -- first tab, takes focus
#                        (badge -> term).
#   goterm: ready        script b: exec GOEDIT.ELF -- second tab, last
#                        declare, so the editor holds focus when the batch
#                        fires.
#   goedit: present      --input-chords: the whole journey in ONE batch on
#                        the documented keystroke-release marker (the
#                        editor's first frame is on the scanout, so it is
#                        already in its event loop). The order inside the
#                        batch is load-bearing, spelled out leg by leg:
#
#     x y z          a typed run into the scratch buffer -> `goedit: dirty`
#     ?              M121c: the app's own '?' opens the registry-fed hint
#                    overlay -> `goedit: hints n=27` + the `hints row` dump
#     down x6        nav strokes the modal consumes -- dwell so the kind-4
#                    snapshot armed on `hints n=` streams a frame while
#                    the plate is still up
#     escape         -> `goedit: hints close`
#     ctrl-z         M121e: `gotabwm: undo id=` routes to the focused tab
#                    and the buffer's ring answers `goedit: undo n=0`
#     ctrl-shift-pageup / pagedown
#                    M121b move pair on the 2-cell rail: GE steps left
#                    then back right -> `gotabwm: reorder <from>-><to>`
#     ctrl-shift-n   M121b pin: `gotabwm: pin id=<n> on`, the pinned cell
#                    jumps to the strip front
#     ctrl-shift-p s e t t return
#                    M121a palette: `palette open n=`, the seat modal's
#                    own sink (badge -> seat), subsequence filter `q=sett`
#                    narrows to a Settings row, return execs it ->
#                    `palette exec GOSET.ELF` + `palette dismiss` (the
#                    palette's catalog is tabs/recents/settings/help/
#                    chords -- a settings pick is the deterministic exec
#                    row, go-wm-seat run 15's exact leg)
#     ctrl-shift-w   M121b close of the STILL-FOCUSED tab: GOSET's exec
#                    is in flight but its declare cannot have landed
#                    (0.25 s/stroke vs a >=1 s measured-boot declare), so
#                    the close provably hits GOEDIT -> `host close id=` +
#                    `tab close id=` + `close`, focus falls to GOTERM
#                    (badge -> term)
#     ctrl-shift-t   M121b reopen: `gotabwm: reopen GOEDIT.ELF` pops the
#                    LIFO the close just pushed; the re-exec declares
#                    after the batch ends
#
#   goedit: state restored  script c: the run's echo. The re-exec'd
#                        editor's own restore receipt is the journey's
#                        last link -- it can only print after the reopen
#                        round-tripped bin -> re-exec -> declare ->
#                        restore_answer. `gotabwm: rail n=3` was tried
#                        first and is NOT a usable anchor: markRail
#                        dedupes on (n,focus) and the seat's composite
#                        paints starve behind the chord backlog, so the
#                        three-tab state never earned a print (observed
#                        first run: n=3 unprinted while tabs=3 stood).
#
# Why nothing follows an exec/reopen chord inside the batch: cv-input
# paces one batch at a fixed 0.25 s/stroke (the go-wm-hid run-16 note),
# and a re-exec'd or exec'd app declares seconds later -- any chord that
# needed the NEW focus would land on the OLD one. Every leg after the
# palette's `return` is therefore a seat-scope chord acting on the
# pre-declare focus, which is exactly what makes the close target
# provable instead of racy.
vgate_file script-09a.txt <<'EOF'
dui focus 0
set GOMAXPROCS=1
exec GOTERM.ELF
EOF

vgate_file script-09b.txt <<'EOF'
exec GOEDIT.ELF
EOF

vgate_file script-09c.txt <<'EOF'
dui
echo rx-m121f-ok
EOF

vgate_run 09 -- \
    --via-virtio --cvc-snap \
    --screen '$RUN_DIR/screen-09' \
    --snapshot-out '$RUN_DIR/snap-09' \
    --snapshot-after 'gotabwm: launcher presented' \
    --snapshot-after 'goedit: state restored' \
    --script '$RUN_DIR/script-09a.txt' \
    --script-after 'dogfood: seat' \
    --script2 '$RUN_DIR/script-09b.txt' \
    --script2-after 'goterm: ready' \
    --input-chords 'x,y,z,?,down,down,down,down,down,down,escape,ctrl-z,ctrl-shift-pageup,ctrl-shift-pagedown,ctrl-shift-n,ctrl-shift-p,s,e,t,t,return,ctrl-shift-w,ctrl-shift-t' \
    --input-chords-after 'goedit: present' \
    --script3 '$RUN_DIR/script-09c.txt' \
    --script3-after 'goedit: state restored' \
    --script-expect 'rx-m121f-ok' --script-expect-tail 90 --timeout 420

# The LIVE default seat, restored-empty: no starter GOSH, no demo
# choreography, no persisted wm row (the whole point of this spec).
vgate_assert 09 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 09 serial-contains 'gotabwm: mode live'
vgate_assert 09 serial-absent 'gotabwm: mode demo'
vgate_assert 09 serial-absent 'dogfood: gosh'

# --- the two exec'd tabs ---------------------------------------------------
vgate_assert 09 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 09 serial-contains 'goterm: declare accepted'
vgate_assert 09 serial-contains 'goterm: ready'
vgate_assert 09 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 09 serial-contains 'goedit: declare accepted'
vgate_assert 09 serial-contains 'goedit: present'
vgate_assert 09 serial-contains 'gotabwm: rail n=2'

# --- the typed run: the seat saw the keys, the buffer went dirty ----------
vgate_assert 09 serial-contains 'gotabwm: key'
vgate_assert 09 serial-contains 'goedit: dirty'

# --- M121c leg: '?' opens the registry-fed overlay; Esc closes it ---------
# n= is the live registry's own row count for GOEDIT (the app's rows plus
# the seat's globals -- 33 at this revision); the two rows below are the
# journey's own chords made visible -- the palette's summon and the undo
# dispatch.
vgate_assert 09 serial-contains 'goedit: hints n=33'
vgate_assert 09 serial-contains 'goedit: hints row ctrl+shift+p summon the command palette'
vgate_assert 09 serial-contains 'goedit: hints row ctrl+z dispatch undo'
vgate_assert 09 serial-contains 'goedit: hints close'

# --- M121e leg: ctrl+z routed to the focused tab; the ring reverted -------
vgate_assert 09 serial-contains 'gotabwm: undo id='
vgate_assert 09 serial-contains 'goedit: undo n=0'
vgate_assert 09 serial-absent 'goedit: undo none'
# The revert's own paint: the buffer returned to the startup-empty state,
# so the M123b plate marker fired a second time.
vgate_assert 09 serial-contains 'goedit: empty '

# --- M121b legs: move pair, pin, close, reopen -----------------------------
vgate_assert 09 serial-count 'gotabwm: reorder ' 2
vgate_assert 09 serial-contains 'gotabwm: pin id='
vgate_assert 09 serial-contains 'gotabwm: host close id='
vgate_assert 09 serial-contains 'gotabwm: tab close id='
# The app-side half of the same close: the WIN_CLOSE the seam delivers is
# observed and the editor exits by its own receipt. `gotabwm: close` is
# NOT pinnable here -- that marker is the seat's bounded-loop exit line,
# and this boot's seat is live mode (mode demo absent above), whose loop
# never ends before the runner's hard vm.stop.
vgate_assert 09 serial-contains 'goedit: close'
vgate_assert 09 serial-contains 'gotabwm: reopen GOEDIT.ELF'
vgate_assert 09 serial-absent 'gotabwm: reopen missing '

# --- M121a leg: palette open -> subsequence filter -> exec ----------------
vgate_assert 09 serial-contains 'gotabwm: palette open n='
vgate_assert 09 serial-contains 'gotabwm: palette filter q=sett n='
vgate_assert 09 serial-contains 'gotabwm: palette exec GOSET.ELF'
vgate_assert 09 serial-contains 'gotabwm: palette dismiss'
# The plate's presented-frame receipt — the snapshot arm above keys on
# this line, never on the open marker: a frame carrying the plate exists
# on the scanout only after a composite actually presented it.
vgate_assert 09 serial-contains 'gotabwm: launcher presented'
vgate_assert 09 serial-absent 'gotabwm: palette missing '
vgate_assert 09 serial-absent 'gotabwm: palette empty'
# A seat-spawned exec prints no `exec: loaded` (that is the monitor
# command's line); the measured-boot receipt is the kernel-side record.
vgate_assert 09 serial-contains 'verdict=measured name=GOSET.ELF'
vgate_assert 09 serial-contains 'goset: declare accepted'
vgate_assert 09 serial-contains 'goset: open id='

# --- the landing: both async declares made their own receipts -------------
# GOSET's declare/ready/open lines are its hosted proof; the reopened
# GOEDIT's `state restored` is the reopen's -- it can only print on the
# LIFO's re-exec path, never on a fresh exec.
vgate_assert 09 serial-contains 'goset: ready '
vgate_assert 09 serial-contains 'goset: present'
vgate_assert 09 serial-contains 'goedit: state restored'
vgate_assert 09 serial-count 'goedit: declare accepted' 2
# Four tab opens over the boot: GOTERM, GOEDIT, the palette's GOSET, and
# the re-exec'd GOEDIT the reopen raised.
vgate_assert 09 serial-count 'gotabwm: tab open id=' 4
# The live-persistence proof needs >120 consumed heartbeats; a fast
# journey can reach rx-m121f-ok in ~70, so the 90 s expect tail holds the
# boot long enough to cross the demo bound deterministically.
vgate_assert 09 serial-contains 'gotabwm: live steady tabs='
vgate_assert 09 serial-contains 'rx-m121f-ok'

# --- M121d leg: the badge's transition lines -------------------------------
vgate_assert 09 serial-contains 'gotabwm: focus scope=seat'
vgate_assert 09 serial-contains 'gotabwm: focus scope=term title=Term'
vgate_assert 09 serial-contains 'gotabwm: focus scope=app title=Edit'

# --- zero-pointer proof -----------------------------------------------------
# No pointer phase was armed, and none of the pointer-produced markers
# exist: the rail-click, the tty drag-select pair, and the drag/drop
# family are all pointer-only paths (boot 04 and boot 08 carry them).
vgate_assert 09 serial-absent 'gotabwm: rail-click'
vgate_assert 09 serial-absent 'dui: term sel'
vgate_assert 09 serial-absent 'gotabwm: drag'

vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 serial-absent 'exited status=139'

# M123e (#2579): no serial-only refusals in this boot -- every `rc=-<n>` /
# `refuse[d]` line pairs with a UI-surface marker (rules in refusal-pair.py).
vgate_assert 09 python <<'PY'
import os
exec(compile(open(os.path.join(os.environ["RUN_DIR"], "refusal-pair.py")).read(),
             "refusal-pair.py", "exec"))
PY

# The journey as ONE ordered chain -- each marker located strictly after
# the one before it, so no leg can pass on a stale or reordered log.
vgate_assert 09 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
def at(sub, start=0):
    i = ser.find(sub, start)
    if i < 0:
        sys.exit("missing %r (after %d)" % (sub, start))
    return i
i_seat = at("dogfood: seat")
i_term = at("goterm: ready", i_seat)
i_edit = at("goedit: present", i_term)
i_dirty = at("goedit: dirty", i_edit)
i_hints = at("goedit: hints n=", i_dirty)
i_hclose = at("goedit: hints close", i_hints)
# The undo leg pins route AND effect, never their serial order: the kernel
# delivers the ctrl-z KEY_DOWN straight to the focused app (goedit's own
# binding reverts the ring) while the seat's `undo id=` names the route when
# it drains its own event queue — under an input burst that is millions of
# scheduler-runs after the app's answer (applyUndo's own contract; go-wm-hid
# run 17 pins the same "not pinned" rule). What IS ordered: app-side the
# revert follows the escape that closed hints (one input queue), and
# seat-side the route precedes the move chord (one event queue). The route
# therefore anchors on the batch's own fire point, not on an app marker.
i_undo = at("goedit: undo n=0", i_hclose)
i_uroute = at("gotabwm: undo id=", i_edit)
i_move = at("gotabwm: reorder ", i_uroute)
i_pin = at("gotabwm: pin id=", i_move)
i_popen = at("gotabwm: palette open n=", i_pin)
i_pfilter = at("gotabwm: palette filter q=sett n=", i_popen)
i_pexec = at("gotabwm: palette exec GOSET.ELF", i_pfilter)
i_close = at("gotabwm: tab close id=", i_pexec)
i_reopen = at("gotabwm: reopen GOEDIT.ELF", i_close)
i_gset = at("goset: declare accepted", i_pexec)
i_edit2 = at("goedit: declare accepted", i_reopen)
i_rest = at("goedit: state restored", i_edit2)
i_ok = at("rx-m121f-ok", i_rest)
print("M121f journey chain OK: seat -> goterm -> goedit -> dirty -> "
      "hints -> hints-close -> undo(effect@%d) + undo-route@%d -> reorder -> "
      "pin -> palette -> filter -> exec -> close -> reopen -> state-restored "
      "(goset declare@%d, edit redeclare@%d)"
      % (i_undo, i_uroute, i_gset, i_edit2))
PY

# The M121d badge's serial order, as an ordered subsequence (extra lines
# are legal -- GOTERM's retitle can re-report, and the two trailing
# declares race): boot seat -> GOTERM's declare (term) -> GOEDIT's
# declare (app) -> the palette's seat-modal sink -> back to Edit on
# dismiss -> the close landing on term -> the reopened Edit. GOSET's
# Settings badge is pinned only after the palette exec -- a declare's
# arrival against seat-processed chords is a race both directions.
vgate_assert 09 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = [(m.start(), m.group(1), (m.group(2) or "").strip())
         for m in re.finditer(
             r"(?m)^gotabwm: focus scope=(\w+)(?: title=(.*))?$", ser)]
popen = ser.index("gotabwm: palette open n=")
close = ser.index("gotabwm: tab close id=")

def match(chain, seq, label):
    i = 0
    for want_s, want_t in chain:
        while i < len(seq) and not (seq[i][1] == want_s
                                    and seq[i][2].startswith(want_t)):
            i += 1
        if i >= len(seq):
            sys.exit("badge walk: no %r in %s (lines seen: %r)"
                     % ((want_s, want_t), label, seq))
        i += 1

# The whole-run walk, as an ordered subsequence: boot seat -> TERM's
# declare -> Edit's declare -> palette's seat modal -> dismiss back to
# Edit -> the close's term landing -> the reopened Edit. Settings is NOT
# in the spine: GOSET's exec is in flight while the seat chews the
# close+reopen chords, and its declare badge lands wherever its boot
# finishes -- before the close's term under a starved seat (the authored
# order), after the reopen's Edit on a fast drain (both observed). What
# IS pinned: the exec cannot declare before the seat fired it.
match([("seat", ""), ("term", "Term"), ("app", "Edit"),
       ("seat", ""), ("app", "Edit"), ("term", "Term"),
       ("app", "Edit")],
      lines, "journey")
pexec = ser.index("gotabwm: palette exec GOSET.ELF")
if not any(s == "app" and t.startswith("Settings") and p > pexec
           for p, s, t in lines):
    sys.exit("badge walk: no app/Settings badge after the palette exec "
             "(lines seen: %r)" % lines)
print("M121d badge walk OK: seat -> Term -> Edit -> seat(palette) -> "
      "Edit -> Term(close) -> Edit(reopen); Settings badge unpinned")
PY

# ---------------------------------------------------------------------------
# The pixel legs -- two kind-4 raws: the palette's plate and the badge's
# own rect. The '?' overlay's pixel leg was cut after two observed misses:
# the host's marker->capture latency outlives the overlay's ~1.75 s open
# window at this log size (the PNG lands post-Esc on the editor's own
# dark field, which is inside the Surface tolerance) -- and the overlay's
# `hints row` dump is BY DESIGN its painted content ("the serial-readable
# copy of the plate"), so the serial pins carry this leg's proof.
# ---------------------------------------------------------------------------

# snap-09-0.raw: the palette's plate -- the launcher's second face paints
# the left strip (x 0..264, full height): Surface fill, the Accent edge
# rule (observed at x~252 under the seat's padding, not a pinned column),
# and field/row ink.
vgate_assert 09 snapshot 'snap-09-0.raw' <<'PY'
import sys
from collections import Counter
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %d" % (len(raw), W * H * 4))
def px(x, y):
    o = (y * W + x) * 4
    return (raw[o + 2], raw[o + 1], raw[o])
modal = Counter(); accent = ink = total = 0
for y in range(30, 700):
    for x in range(4, 258):
        r, g, b = px(x, y)
        total += 1
        modal[(r, g, b)] += 1
        if min(r, g, b) >= 150:
            ink += 1
        if abs(r - 0x3b) <= 48 and abs(g - 0x82) <= 48 and abs(b - 0xf6) <= 48:
            accent += 1
best, best_n = modal.most_common(1)[0]
dist = max(abs(best[0] - 0x22), abs(best[1] - 0x2d), abs(best[2] - 0x35))
print("palette strip %d px: modal=#%02x%02x%02x n=%d ink=%d accent=%d"
      % (total, best[0], best[1], best[2], best_n, ink, accent))
assert dist <= 4, ("the palette strip is not Surface-filled (modal "
    "#%02x%02x%02x) -- the plate did not paint" % (best[0], best[1], best[2]))
assert best_n >= total // 2, "palette strip not covered by its plate"
assert accent >= 100, "no Accent edge rule / field ring on the palette (%d)" % accent
assert ink >= 100, "no field/row ink inside the palette (%d)" % ink
PY

# snap-09-1.raw: the M121d badge's own rect after the reopen's restore --
# the same tokens the go-wm-seat run-20 check pins: the ChromeBg panel,
# the Accent scope chip/rule and Ink title text, BGRX-decoded here.
vgate_assert 09 snapshot 'snap-09-1.raw' <<'PY'
import sys
from collections import Counter
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot is %d bytes, want %d" % (len(raw), W * H * 4))
def px(x, y):
    o = (y * W + x) * 4
    return (raw[o + 2], raw[o + 1], raw[o])
x0, y0, pw, ph = 1124 - 4 - 216, 720 - 8 - 20, 216, 20
modal = Counter(); accent = ink = total = 0
for y in range(y0, y0 + ph):
    for x in range(x0, x0 + pw):
        r, g, b = px(x, y)
        total += 1
        modal[(r, g, b)] += 1
        if min(r, g, b) >= 150:
            ink += 1
        if abs(r - 0x3b) <= 32 and abs(g - 0x82) <= 32 and abs(b - 0xf6) <= 32:
            accent += 1
best, best_n = modal.most_common(1)[0]
dist = max(abs(best[0] - 0x11), abs(best[1] - 0x17), abs(best[2] - 0x1c))
print("badge rect %dx%d (%d px): modal=#%02x%02x%02x n=%d accent=%d ink=%d"
      % (pw, ph, total, best[0], best[1], best[2], best_n, accent, ink))
assert dist <= 4, ("the badge rect is not the seat's ChromeBg (modal "
    "#%02x%02x%02x) -- the panel was not painted"
    % (best[0], best[1], best[2]))
assert best_n >= 3000, "the badge panel does not cover its rect"
assert accent > ph, "no scope chip / seat rule on the badge"
assert ink >= 20, "no title text on the badge"
PY
