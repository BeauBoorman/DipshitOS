# go-wm-seat.spec -- M57a/b/c (issues #1313/#1317/#1318) class-B gate: a Go WM
# (GOTABWM.ELF) registers the kernel render-server seat (slot 65), composites a
# blank desktop, manages its OWN Go windows, and HOSTS GOCALC.ELF (M62h)
# plus NOTE.ELF (M66c; the Zig notepad it replaced is deleted in #1485).
#
# M57a: REGISTER (slot 65 cmd 1), the seam-B scanout grant, and a REQUEST_PRESENT
# loop paced by the kind-18 COMPOSITE_TICK. M57b: the seat's own window
# lifecycle (open, chrome descriptor, a kernel-clamped rect, focus/blur, a
# WM-seam close, the client-death probe). M57c: interop — GOCALC.ELF
# discovers the seat by process name, declares over the WM_RPC
# mailbox, and is focused, given the full viewport, and closed by the seat.
# Zig CALC.BIN is gone (M62h / #1406).
#
# One headless boot arms the GPU, execs GOTABWM.ELF, queries the seat and the
# window registry while both are live, execs GOCALC.ELF under it, and lets the
# program exit cleanly (the kernel unregisters the seat, falling back to the
# shim). Serial markers are the proof; each is printed only after its syscall
# returned.
#
# M59 (issue #1298) note: the COMPILED default is now the Go seat, so this
# spec seeds `wm=none` in its share to keep what it actually proves -- the
# seat's explicit, opt-in registration path -- separate from the default flip
# (go-wm-default.spec owns that). Its "shim at boot" asserts are therefore
# about the seeded setting, not about the out-of-the-box boot.
# M63f (#1463): re-verified green after GOTABWM maxTicks 90 (M73z;
# was 48). No HID here.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gocalc.sh    ->  .build/go/GOCALC.ELF
#
# M79k (#1720) adds run 06: the notify seam. GOFILES.ELF is the adopter (it
# raises a toast on a completed copy, over the real WM_RPC kind-12 frame, to
# a LIVE seat); the run proves the whole chain — the app's own ack, the
# seat's queue line, a kind-4 snapshot of the toast ON the composed scanout
# (exact-RGB, straight out of the guest), and a `--pointer-virtio` click on
# the toast that dismisses it and focuses the sender.
#
# M99d (#2182) adds runs 08-11: the audible half of the same seam, played
# through the M99b vi.AudioStream mixer path (never the blocking slot-43
# drain), plus the GOSET volume row on kernel slot 44. Run 08 is the full
# sound-on chain — the seat boots with --sound, re-applies the persisted
# audio_volume row at startup, probes and synthesizes once, then a GOFILES
# toast plays the chime and the NEXT composite tick prints `notify-sound
# played` with the kernel's own completed counter. The same run drives
# GOSET.ELF's typed `audio_volume=40` row and reads the kernel's `sound`
# report for `sound: vol=40`. Runs 09-11 are the silence contracts: a
# DND-held notice, a `notify_sound=off` boot, and a soundless VM each keep
# the toast working while `43 sys_audio_play calls=0` (the kernel's own
# counter — stream opens and legacy plays share it) proves nothing ever
# reached the audio path. HOST PREREQUISITE for run 08:
#   bash tools/go/build-goset.sh -> .build/go/GOSET.ELF
#
# exec-order: assert-proven -- each run ends on a marker only its script prints
# (`rx-gotabwm-ok`, `rx-gotabwm-np-ok`, `rx-gotabwm-chrome-ok`), and every stage
# gate waits on guest output the program, the kernel and the hosted app produce
# (`gotabwm: win focus`, `gotabwm: present`, `wm: unregistered, shim resumed`).
# The M99d runs are graded the strong way: 08 ends on `gotabwm: notify-sound
# played` (a marker only the seat's completed-drain check can print) and
# 09-11 end on their own `rx-*` echoes, gated behind guest markers
# (`gofiles: notify sent` / `gotabwm: notify dismiss id=`).
#
# M71c (#1562) adds run 03: the seat's OWN clock/status chrome, on an EMPTY
# strip. Run 01/02 host a full-viewport client that the kernel repaints every
# tick, which covers the bottom-right panel; with no client exec'd the panel is
# the seat's last write and is stable in the capture. The capture is timed to
# `gotabwm: present` because the tick loop is paint -> chromeTick -> present, so
# that marker is the first moment the frame is both painted and flushed
# (capturing on `gotabwm: clock` races the flush and reads a black resource --
# measured 2026-09-21).
# M66c (#1445 retarget, #1485 retirement): the client is NOTE.ELF, the Go
# successor to the Zig notepad, and the Zig binary itself is now GONE. The
# lifecycle vocabulary is shared by design (`note:` mirrors `notepad:`), so the
# assertions below moved by prefix alone. The coverage that app alone had moved
# to GOEDIT.ELF (find/goto, the unsaved-decline contract) or GOCOMP.ELF (its
# clipboard+timer composition); the theme-token boots were retired with it.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF
#
# M79a (#1704): the seat is LIVE by default -- no run budget, no auto-close,
# no strip choreography. The bounded M57-era demo is DEMO mode, opted in by
# the PRESENCE of /host/GOTABWM.DEMO; the setup below seeds it so runs 01-04
# drive exactly the choreography they always have. Run 05 REMOVES the trigger
# before exec and proves the product default: the loop ticks PAST the demo
# ceiling (maxTicks 90) with the tab still open, nothing ever says `host
# done`/`tab close`, and the run ends by KILLING the seat -- process exit,
# which still unwinds through the kernel's exit seam (`wm: unregistered`).
#
# M109e (#2401) adds runs 12-14: the seat's agent watch on the M109c audit
# lane. The indicator is the AGENT badge in the clock panel's badge row, lit
# while a MAC-verified session-open receipt stands without its close; the
# notify lanes are seat toasts (sender id 0, the hostdrop shape) for the
# three agent milestones — FLINT.ELF commit / push and STORE.ELF install —
# recognized inside verified ok+exit-0 gosh.run receipts. The flag is the
# agent-hmac row's allowlist, the ADR 0051 D7 posture: run 12/13's share
# names GOTABWM.ELF (and OWNERS.TXT binds the image uid_system-owned, the
# same serve condition agentd itself meets), run 14's names only
# AGENTD.ELF,GOTOP.ELF — valid signed receipts sit in AGENT/AUDIT the whole
# run and the boot stays byte-silent. Run 12's snapshot reads the badge and
# the toast off the guest's own composed scanout; the forged close proves
# the MAC is the gate. Runs 01/05/11 also assert `gotabwm: agent` absent —
# on the seeded share there is no SECRETS.TXT at all.

vgate_name go-wm-seat "issues #1313/#1317/#1318 M57a+b+c: a Go WM registers the slot-65 seat and HOSTS GOCALC.ELF/NOTE.ELF/GOVIEW.ELF on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# Phase 1: the seeded `wm=none` keeps this boot shim-only, then the seat is
# opted in explicitly.
vgate_file script.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

# Phase 2: forwarded while the program holds its own window and is WAITING for
# the blur. `dui focus 0` (the fixed terminal window) hands focus away, so the
# kernel routes WIN_BLUR to the seat. The `wm` + `dui` queries land while the
# seat's window is live (5 = the four fixed layers + the seat's Go window).
# Then GOCALC.ELF is exec'd under the Go seat.
vgate_file script2.txt <<'EOF'
wm
dui
dui focus 0
exec GOCALC.ELF
EOF

# Phase 3: after the program exits and the kernel unregisters the seat, the
# report is back to the shim and the registry is back to its pre-program count
# (the hosted app closed, the leaked probe window reaped).
vgate_file script3.txt <<'EOF'
wm
dui
echo rx-gotabwm-ok
EOF

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
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.exists(src):
    sys.exit("GOCALC.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "GOCALC.ELF"))
print("staged GOCALC.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOCALC.ELF")))
# M59 (issue #1298): the compiled default is the Go seat now. Seed `wm=none`
# so this boot composites via the shim and the seat arrives only where the
# script asks for it -- the point of THIS spec (go-wm-default.spec owns the
# default-flip proof). `none` is the documented shim-only seat value.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("seeded SETTINGS.TXT (wm=none: shim-only boot, explicit seat opt-in)")
# M79a (#1704): the demo choreography is opt-in (the trigger's PRESENCE).
# Runs 01-04 drive it, so seed the fixture here; run 05 removes it with
# `vf rm GOTABWM.DEMO` before exec and proves the live default instead.
# A daily session never stages this file and gets the live seat.
with open(os.path.join(share, "GOTABWM.DEMO"), "w") as f:
    f.write("demo\n")
print("seeded GOTABWM.DEMO (seat demo mode: bounded choreography)")
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

# M79k (#1720): run 06 hosts GOFILES.ELF as the NOTIFY adopter, so stage it
# and the fixture its copy needs. HOST PREREQUISITE:
#   bash tools/go/build-files.sh  ->  .build/go/GOFILES.ELF
#
# The fixture is one file plus one directory, and that is exactly what the
# run's key batch needs: dirs sort first, so entry 0 is SUB and entry 1 is
# SOURCE.TXT. See run 06's input note for the exact strokes.
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOFILES.ELF")
if not os.path.exists(src):
    sys.exit("GOFILES.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-files.sh")
shutil.copy(src, os.path.join(share, "GOFILES.ELF"))
notify = os.path.join(share, "NOTIFY")
sub = os.path.join(notify, "SUB")
os.makedirs(sub, exist_ok=True)
with open(os.path.join(notify, "SOURCE.TXT"), "w") as f:
    f.write("notify-adopter-payload\n")
print("staged GOFILES.ELF (%d bytes) + NOTIFY/SOURCE.TXT + NOTIFY/SUB"
      % os.path.getsize(os.path.join(share, "GOFILES.ELF")))
PY

# M99d (#2182): run 08 hosts GOSET.ELF to drive the volume row — the typed
# `audio_volume=40` line lands on kernel slot 44 through the panel's normal
# set+save path. HOST PREREQUISITE: bash tools/go/build-goset.sh
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

# M121a (#2564): run 15 hosts GOEDIT.ELF so the palette's 'edit' leg has a
# tab to focus. HOST PREREQUISITE:
#   bash tools/go/build-goedit.sh -> .build/go/GOEDIT.ELF
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOEDIT.ELF")
if not os.path.exists(src):
    sys.exit("GOEDIT.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goedit.sh")
shutil.copy(src, os.path.join(share, "GOEDIT.ELF"))
print("staged GOEDIT.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOEDIT.ELF")))
PY

# M71h (#1567): run 04 hosts the image viewer, so stage it and the QOI fixture
# it opens. HOST PREREQUISITE: bash tools/go/build-goview.sh -> .build/go/GOVIEW.ELF
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOVIEW.ELF")
if not os.path.exists(src):
    sys.exit("GOVIEW.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goview.sh")
shutil.copy(src, os.path.join(share, "GOVIEW.ELF"))
shutil.copy("tests/fixtures/qoi/viewer_160x120.qoi", os.path.join(share, "TEST.QOI"))
print("staged GOVIEW.ELF into share (%d bytes) + TEST.QOI" %
      os.path.getsize(os.path.join(share, "GOVIEW.ELF")))
PY

# M109e (#2401): runs 12-14 drive the agent watch through staged
# alternate shares. The receipts are real lane files — the JSON line the
# daemon's emit writes plus its 64-hex HMAC-SHA256 under the pinned
# agent-hmac row — so the seat verifies them against the same secret it
# is provisioned with. Staged files publish atomically through `vf mv`
# (the lane's own publish shape), which is what makes a mid-run arrival
# a live receipt rather than boot backlog.
vgate_setup_python <<'PY'
import hashlib, hmac, json, os, shutil, sys
rd = os.environ["RUN_DIR"]
run = rd
elf = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(elf):
    sys.exit("GOTABWM.ELF missing (expected " + elf + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
KEY = "a5" * 32  # the pinned receipt key (the go-agentd.spec vector)

def receipt(agent, verb, args, result):
    line = ('{"seq":1,"epoch":"b0000001","agent":%s,"verb":%s,"args":%s,'
            '"ts":100,"mono":200,"result":%s}'
            % (json.dumps(agent), json.dumps(verb), args, json.dumps(result)))
    mac = hmac.new(KEY.encode(), line.encode(), hashlib.sha256).hexdigest()
    return (line + "\n" + mac + "\n").encode()

def write_at(root, rel, body):
    dst = os.path.join(root, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "wb") as f:
        f.write(body if isinstance(body, bytes) else body.encode())

def stage(tag, secrets_rows, audit, staged):
    alt = os.path.join(run, tag + "-share")
    os.makedirs(alt, exist_ok=True)
    shutil.copy(elf, os.path.join(alt, "GOTABWM.ELF"))
    # wm=none keeps the boot shim-only (the spec's Phase-1 contract), the
    # seat is opted in explicitly, and wm!=gotabwm suppresses the
    # first-boot workspace exec the empty SESSION.TABS would trigger.
    write_at(alt, "SETTINGS.TXT", "#v2\nwm=none\n")
    # OWNERS.TXT binds GOTABWM.ELF uid_system-owned with no non-owner
    # write — the serve condition an allowlisted image must meet.
    write_at(alt, "OWNERS.TXT", "#v1\nGOTABWM.ELF\t644\t0\t-\n")
    write_at(alt, "SECRETS.TXT", secrets_rows)
    for rel, body in audit:
        write_at(alt, os.path.join("AGENT", "AUDIT", rel), body)
    for rel, body in staged:
        write_at(alt, os.path.join("AGENT", "STAGED", rel), body)
    return alt

GOSH = lambda cmd, st: ('{"cmd":%s,"timeout_ms":10000,"exit_status":%d}'
                        % (json.dumps(cmd), st))

secrets_on = ("#v1\nagent-hmac\t1000\t" + KEY + "\tAGENTD.ELF,GOTOP.ELF,GOTABWM.ELF\n")
secrets_off = ("#v1\nagent-hmac\t1000\t" + KEY + "\tAGENTD.ELF,GOTOP.ELF\n")

# Run 12's share: one backlog fs.read (the catch-up leg), then the staged
# publishes — session open, the three milestones, and a forged close.
a12 = stage("agent", secrets_on,
    audit=[("RCPT-b0000001-00000001",
            receipt("devin", "fs.read", '{"path":"APP/main.go","size":4,"sha256_8":"deadbeef"}', "ok"))],
    staged=[
        ("R1", receipt("devin", "session", '{"event":"open"}', "ok")),
        ("R2", receipt("devin", "gosh.run", GOSH('FLINT.ELF commit -m "x"', 0), "ok")),
        ("R3", receipt("devin", "gosh.run", GOSH("FLINT.ELF push --remote=10.0.0.2:4750 --stream=main", 0), "ok")),
        ("R4", receipt("devin", "gosh.run", GOSH("STORE.ELF install main --remote=10.0.0.2:4750", 0), "ok")),
        # The forged close: a valid-shape file with a junk MAC — it must
        # be named `rcpt bad`, must not print a close marker, and must
        # not take the badge down.
        ("R5", b'{"seq":1,"epoch":"b0000001","agent":"devin","verb":"session",'
               b'"args":{"event":"close"},"ts":100,"mono":200,"result":"ok"}\n'
               + b"0" * 64 + b"\n"),
    ])

# Run 13's share: the open is boot backlog (the catch-up lights the
# badge from it) and the real close publishes live.
a13 = stage("agent-close", secrets_on,
    audit=[("RCPT-b0000001-00000001",
            receipt("devin", "session", '{"event":"open"}', "ok"))],
    staged=[("R2", receipt("devin", "session", '{"event":"close"}', "client_close"))])

# Run 14's share: verifiable receipts and the row exist — but the
# allowlist does not name the seat, so the watch is the flags-off
# posture: no init marker, no poll, no output.
a14 = stage("agent-off", secrets_off,
    audit=[
        ("RCPT-b0000001-00000001", receipt("devin", "session", '{"event":"open"}', "ok")),
        ("RCPT-b0000001-00000002", receipt("devin", "gosh.run", GOSH('FLINT.ELF commit -m "x"', 0), "ok")),
    ],
    staged=[])
print("agent-watch shares staged: %s / %s / %s" % (a12, a13, a14))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-ok' --timeout 300

# --- M57a: the seat and the blank desktop --------------------------------
vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
# The seat is opt-in: the seeded `wm=none` leaves the boot shim-only (the
# autostart reports nothing for that seat), and the run's `wm` query before
# the exec and after the exit both report shim.
vgate_assert 01 serial-count 'wm: none (shim compositing)' 2
# The program's own marker chain (each printed after its syscall succeeded).
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: seat-taken'
vgate_assert 01 serial-contains 'gotabwm: scanout'
vgate_assert 01 serial-contains 'gotabwm: draw'
vgate_assert 01 serial-contains 'gotabwm: holding seat'
vgate_assert 01 serial-contains 'gotabwm: tick'
vgate_assert 01 serial-contains 'gotabwm: present'
vgate_assert 01 serial-contains 'gotabwm: close'
vgate_assert 01 serial-contains 'gotabwm OK'
# The kernel's own report naming the live seat, and the clean teardown.
vgate_assert 01 serial-contains 'wm: registered pid='
vgate_assert 01 serial-contains 'wm: present_seq='
vgate_assert 01 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 01 serial-contains 'rx-gotabwm-ok'

# --- M57b: the seat's own Go window lifecycle ----------------------------
vgate_assert 01 serial-contains 'gotabwm: win open id='
vgate_assert 01 serial-contains 'gotabwm: win chrome'
vgate_assert 01 serial-contains 'gotabwm: win rect '
vgate_assert 01 serial-contains 'gotabwm: win focus'
vgate_assert 01 serial-contains 'gotabwm: win blur'
vgate_assert 01 serial-contains 'gotabwm: win close'
vgate_assert 01 serial-contains 'gotabwm: win gone'
vgate_assert 01 serial-contains 'gotabwm: win leak id='
# The kernel CLAMPED the WM's proposed 4000,3000 position to the 1280x720
# scanout: x is min(4000, 1280-256) = 1024, y is min(3000, 720-192) = 528.
vgate_assert 01 serial-contains 'gotabwm: win rect x=1024 y=528 w=256 h=192'
# While the seat's window is live the registry counts 5 (the four fixed
# terminal/wallpaper/taskbar/dock windows + the seat's Go window).
vgate_assert 01 serial-contains 'dui: windows=5 focused='

# --- M57c: GOCALC.ELF hosted by the Go seat --------------------------------
vgate_assert 01 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 01 serial-contains 'gotabwm: rpc declare id='
vgate_assert 01 serial-contains 'gocalc: declare accepted'
vgate_assert 01 serial-contains 'gocalc: present'
vgate_assert 01 serial-contains 'gotabwm: host focus id='
vgate_assert 01 serial-contains 'gotabwm: host view id='
vgate_assert 01 serial-contains 'gotabwm: host close id='
vgate_assert 01 serial-contains 'gocalc: close'
vgate_assert 01 serial-contains 'gotabwm: host done'
# No residue: the hosted app closed and the leaked probe window was reaped, so
# the registry is back to the four fixed layers only. The seat's own window sat
# at registry index 4 while it was live (one `dui[4]: user` row in the whole
# run) and there is no index-4 row after exit.
vgate_assert 01 serial-contains 'dui: windows=4 focused='
vgate_assert 01 serial-count 'dui[4]: user' 1
# M109e: no agent-hmac row names the seat on this share — the watch's
# flags-off posture is byte-silent even though it exec'd and ran the
# whole choreography.
vgate_assert 01 serial-absent 'gotabwm: agent'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# --- M57c run 02: the Go editor NOTE.ELF ---------------------------------
# Same choreography, a Go tab-aware app. If GOCALC hosts and NOTE.ELF does
# not (or vice versa) the interop would be app-specific.
vgate_file script-02.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
dui focus 0
exec NOTE.ELF
EOF

vgate_file script3-02.txt <<'EOF'
dui
echo rx-gotabwm-np-ok
EOF

vgate_run 02 -- \
    --screen '$RUN_DIR/screen-02' \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-np-ok' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 02 serial-contains 'exec: loaded NOTE.ELF'
# The same interop chain as CALC, for the second app.
vgate_assert 02 serial-contains 'gotabwm: rpc declare id='
vgate_assert 02 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert 02 serial-contains 'gotabwm: host focus id='
vgate_assert 02 serial-contains 'gotabwm: host view id='
vgate_assert 02 serial-contains 'note: resize relayout'
vgate_assert 02 serial-contains 'gotabwm: host close id='
vgate_assert 02 serial-contains 'note: win_close'
vgate_assert 02 serial-contains 'gotabwm: host done'
vgate_assert 02 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 02 serial-contains 'dui: windows=4 focused='
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# --- M71c (#1562) run 03: the seat's own clock/status chrome ----------------
# The seat is opted in and NO client is exec'd, so the strip is empty: the seat
# paints the full-frame blank desktop plus its panel, and nothing covers
# either. `dui focus 0` still runs because the seat's window phase blocks until
# it loses focus (the M57b choreography). `vf rm SESSION.TABS` first: runs
# 01/02 leave a hosted app's session row on this same share, and a
# restored tab prints `tab open id=` — the line this leg asserts absent
# (observed 2026-10-20: a Calc session reexec'd on the run 03 boot).
vgate_file script-03.txt <<'EOF'
set GOMAXPROCS=1
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-03.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-03.txt <<'EOF'
echo rx-gotabwm-chrome-ok
EOF

vgate_run 03 -- \
    --screen '$RUN_DIR/screen-03' \
    --screenshot-after 'rx-gotabwm-chrome-ok' \
    --script '$RUN_DIR/script-03.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'gotabwm: present' \
    --script-expect 'rx-gotabwm-chrome-ok' --timeout 300

vgate_assert 03 serial-contains 'gotabwm: registered'
vgate_assert 03 serial-contains 'gotabwm: scanout'
vgate_assert 03 serial-contains 'gotabwm: holding seat'
vgate_assert 03 serial-absent 'gotabwm: tab open id='
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# --- M71h (#1567) run 04: the seat HOSTS GOVIEW.ELF ------------------------
# The image viewer is a tabapp client, so its real home is the seat's strip,
# and `gview: tab-aware (full-viewport)` plus the resize line are the app's own
# half of deliverable 1 (paint full-viewport in GOTABWM). live-image-viewer
# owns the decoding and both error surfaces; this run owns the hosting: the
# declare is accepted, the canvas is the seat's own 1100x692 viewport, and the
# seat closes the tab (its single-tab budget) and the app exits cleanly.
vgate_file script-04.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-04.txt <<'EOF'
dui focus 0
exec GOVIEW.ELF /host/TEST.QOI
EOF

vgate_file script3-04.txt <<'EOF'
dui
echo rx-gotabwm-view-ok
EOF

vgate_run 04 -- \
    --screen '$RUN_DIR/screen-04' \
    --script '$RUN_DIR/script-04.txt' \
    --script2 '$RUN_DIR/script2-04.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-04.txt' \
    --script3-after 'wm: unregistered, shim resumed' \
    --script-expect 'rx-gotabwm-view-ok' --timeout 300

vgate_assert 04 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 04 serial-contains 'exec: loaded GOVIEW.ELF'
vgate_assert 04 serial-contains 'gotabwm: rpc declare id='
vgate_assert 04 serial-contains 'gview: tab-aware (full-viewport)'
vgate_assert 04 serial-contains 'gview: loaded TEST.QOI 160x120 QOI bytes=340'
vgate_assert 04 serial-contains 'gotabwm: host focus id='
vgate_assert 04 serial-contains 'gotabwm: host view id='
vgate_assert 04 serial-contains 'gview: resize relayout 1280x720'
vgate_assert 04 serial-contains 'gotabwm: host close id='
vgate_assert 04 serial-contains 'gview: win_close'
# WIN_CLOSE is the path the seat drives, and Zig VIEW.BIN's rule for it is
# `view: win_close` + exit 43 with no `exiting 43` line (that line belongs to
# the app's own quit path). The status is the kernel's own report.
vgate_assert 04 serial-contains 'tasks user-exec exited status=43'
vgate_assert 04 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 04 serial-contains 'dui: windows='
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()
# The request is the aspect-fitted 328x264; the GRANTED canvas is the seat's
# scanout (1280x720), which is what "full-viewport" means here. Both must
# appear, in that order, or the app never relayouted.
req = ser.find("gview: open id")
grant = ser.find("gview: resize relayout 1280x720")
assert req >= 0 and grant >= 0, "missing the open or the granted-canvas marker"
assert req < grant, "the resize marker must follow the open marker"
assert re.search(r"gview: open id=[0-9]+ 328x264", ser), "open dimension check failed"
PY

# The face and its source: the marker is one-shot and comes after the seat
# registered, so a gate never has to guess which of VZ's three cases (kernel
# EFI epoch / host `.clock` / uptime) this boot is in.
# M104e (#2272): the seat's one-shot font report, printed at the first
# paint. No FONTS.TXT is staged on this share, so BOTH roles must name the
# documented degrade — ui=bitmap chrome=bitmap — and the seat still paints
# everything this run asserts (the never-blank contract). The marker is
# well-formed, one-shot, and lands after the seat registered.
vgate_assert 03 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
hits = re.findall(r"(?m)^gotabwm: fonts (.*?) ui=(\w+) chrome=(\w+)$", ser)
if not hits:
    sys.exit("no `gotabwm: fonts` marker — the seat never resolved a font")
if len(hits) != 1:
    sys.exit("the fonts marker is one-shot, saw %d" % len(hits))
payload, ui, chrome = hits[0]
if not payload.startswith("manifest="):
    sys.exit("malformed fonts payload: %r" % payload)
if ui != "bitmap" or chrome != "bitmap":
    sys.exit("ui=%s chrome=%s — this share stages no FONTS.TXT, so both "
             "roles must degrade to the bitmap face" % (ui, chrome))
if ser.find("gotabwm: registered") > ser.find("gotabwm: fonts "):
    sys.exit("the fonts marker printed before the seat registered")
print("fonts marker: %s ui=%s chrome=%s — the degrade path, observed"
      % (payload, ui, chrome))
PY

vgate_assert 03 serial-contains 'gotabwm: clock-source '
vgate_assert 03 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
src = re.search(r"(?m)^gotabwm: clock-source (kernel|host|uptime)$", ser)
if not src:
    sys.exit("no well-formed gotabwm: clock-source line (want kernel|host|uptime)")
face = re.search(r"(?m)^gotabwm: clock (\d\d):(\d\d):(\d\d)$", ser)
if not face:
    sys.exit("no well-formed gotabwm: clock HH:MM:SS line")
h, mi, sec = (int(g) for g in face.groups())
if mi > 59 or sec > 59:
    sys.exit("clock face out of range: %s" % face.group(0))
if h > 99:
    sys.exit("clock hours past 99: %s" % face.group(0))
reg = ser.find("gotabwm: registered")
src_i, face_i = src.start(), face.start()
if not (0 <= reg < src_i < face_i):
    sys.exit("clock markers out of order (registered=%d source=%d face=%d)"
             % (reg, src_i, face_i))
if ser.count("gotabwm: clock-source ") != 1:
    sys.exit("the clock-source marker is one-shot, saw %d"
             % ser.count("gotabwm: clock-source "))
print("clock source=%s face=%02d:%02d:%02d (one-shot, after registered)"
      % (src.group(1), h, mi, sec))
PY

# THE chrome pixel assert: the panel's own rect on the SAME frame. The rect is
# chromeRect(1280,720) = ChromeW 148 x ChromeH 20 inset 8 -> (1124,692); the
# probe scales with the capture. Thresholds are the seat's own tokens, and the
# exclusion is the point: the blank desktop is theme Bg (0x182026) and the
# kernel terminal is 0x101418 with 0x00ff00 text, so neither can satisfy a
# ChromeBg-modal panel with no console-green in it. Reported margins came in at
# modal 7848/11840 pixels and >= 3 distinct colours (measured 2026-09-21).
vgate_assert 03 snapshot 'screen-03-after' <<'PY'
import sys, zlib, struct
from collections import Counter
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
x0, y0, pw, ph = 1124, 692, 148, 20
# seat theme tokens: ChromeBg 0x11171c, Ink 0xe6edf3; the kernel terminal is
# 0x101418 bg with 0x00ff00 text. The capture applies a small colour-space
# shift, hence the tolerances below (measured: ChromeBg reads 0x12171c).
chrome_bg = (0x11, 0x17, 0x1c)
modal = Counter(); ink = green = total = 0
for y in range(int(y0 * scale), int((y0 + ph) * scale)):
    for x in range(int(x0 * scale), int((x0 + pw) * scale)):
        r, g, b = px(x, y)
        total += 1
        modal[(r, g, b)] += 1
        if min(r, g, b) >= 150:
            ink += 1
        if g > 150 and r < 120 and b < 120:
            green += 1
best, best_n = modal.most_common(1)[0]
dist = max(abs(best[0]-chrome_bg[0]), abs(best[1]-chrome_bg[1]),
           abs(best[2]-chrome_bg[2]))
print("panel rect %dx%d (%d px): modal=#%02x%02x%02x n=%d distinct=%d "
      "ink=%d console-green=%d"
      % (int(pw*scale), int(ph*scale), total,
         best[0], best[1], best[2], best_n, len(modal), ink, green))
assert dist <= 4, ("the panel rect is not the seat's ChromeBg (modal #%02x%02x%02x "
                   "is %d off 0x11171c) - the panel was not painted"
                   % (best[0], best[1], best[2], dist))
assert best_n >= 3000, ("only %d/%d panel-rect pixels are ChromeBg - the panel "
                        "is not covering its rect" % (best_n, total))
assert len(modal) >= 3, ("the panel rect holds only %d colour(s) - no rule and "
                         "no glyphs, so the chrome is a bare fill" % len(modal))
assert ink >= 20, ("only %d ink-white pixels in the panel rect - the clock face "
                   "did not paint" % ink)
assert green == 0, ("%d console-green pixels inside the panel rect - the kernel's "
                    "terminal is compositing over the seat's scanout" % green)

# M104e: the accent rule still rides the panel's left edge, now through the
# shared plate's rounded silhouette — column x0+1 (the outermost column is
# the 1px Rule stroke). Blue dominance, not a token match: the capture's
# shift is large on saturated blue (measured in M71e: Accent 0x3b82f6 reads
# back ~(78,128,238)), and nothing else on this frame is blue-dominant.
arule = 0
for y in range(int((y0 + 2) * scale), int((y0 + ph - 2) * scale)):
    r, g, b = px(int((x0 + 1) * scale), y)
    if b > 150 and b > r + 40 and b > g + 40:
        arule += 1
assert arule > 0, ("no accent rule on the clock panel's left edge - the "
                   "seat's identity mark did not paint")
print("clock panel accent rule: %d blue-dominant rows" % arule)
PY

# --- M79a (#1704) run 05: LIVE mode persistence --------------------------
# Runs 01-04 opt into the bounded demo (the seeded trigger). This run removes
# the trigger BEFORE exec, so the seat runs its product default: no run
# budget, no auto-close, no choreography. It hosts GOCALC.ELF and simply keeps
# going; `gotabwm: live steady tabs=` prints only once the loop has ticked
# PAST the demo ceiling (maxTicks = 90), and the run then KILLS the seat
# (process exit -- the kernel's exit seam still tears it down, M52). Nothing
# may say `host done`, `tab close id=`, `host close id=`, or `gocalc: close`.
vgate_file script-live.txt <<'EOF'
vf rm GOTABWM.DEMO
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-live.txt <<'EOF'
dui
dui focus 0
exec GOCALC.ELF
EOF

vgate_file script3-live.txt <<'EOF'
kill GOTABWM.ELF
wm
echo rx-gotabwm-live-ok
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-live' \
    --script '$RUN_DIR/script-live.txt' \
    --script2 '$RUN_DIR/script2-live.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-live.txt' \
    --script3-after 'gotabwm: live steady ' \
    --script-expect 'rx-gotabwm-live-ok' --script-expect-tail 30 --timeout 420

vgate_assert 05 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 05 serial-contains 'gotabwm: mode live'
vgate_assert 05 serial-absent 'gotabwm: mode demo'
vgate_assert 05 serial-contains 'gotabwm: registered'
vgate_assert 05 serial-contains 'gotabwm: holding seat'
vgate_assert 05 serial-contains 'gotabwm: present'
vgate_assert 05 serial-contains 'exec: loaded GOCALC.ELF'
vgate_assert 05 serial-contains 'gotabwm: rpc declare id='
vgate_assert 05 serial-contains 'gocalc: declare accepted'
vgate_assert 05 serial-contains 'gotabwm: host view id='
vgate_assert 05 serial-contains 'gotabwm: tab open id='
# The loop outlived the old ceiling, and the tab survived it: the steady
# marker prints only at tick maxTicks+1, nothing auto-closed before then, and
# the absent asserts below pin that nothing closed after.
vgate_assert 05 serial-contains 'gotabwm: live steady tabs='
vgate_assert 05 serial-count 'gotabwm: tick' 91
vgate_assert 05 serial-absent 'gotabwm: host close id='
vgate_assert 05 serial-absent 'gotabwm: tab close id='
vgate_assert 05 serial-absent 'gotabwm: host done'
vgate_assert 05 serial-absent 'gocalc: close'
vgate_assert 05 serial-contains 'wm: unregistered, shim resumed'
vgate_assert 05 serial-contains 'rx-gotabwm-live-ok'
# M109e: 91 polls, never an agent line — flags-off byte-silence on the
# longest-running boot in this spec.
vgate_assert 05 serial-absent 'gotabwm: agent'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'

# --- M79k (#1720) run 06: the notify seam, end to end ---------------------
#
# GOFILES.ELF is the adopter: it raises a toast on a COMPLETED copy, over the
# real WM_RPC wire, to a seat that is LIVE (the GOTABWM.DEMO trigger is
# removed before the exec, the go-wm-seat run 05 pattern — in demo mode the
# single-tab hostTicks countdown closes the app long before an 8-tick toast
# could expire on its own).
#
# The chain this run proves has five links, each with its own marker,
# because each can fail alone:
#
#   gofiles: pasted SOURCE.TXT         the copy really completed
#   gofiles: notify sent <text>        the app's OWN ack — the seat
#                                       answered, so this is not a request
#                                       into the void
#   gotabwm: notify id=<n> <text>      the seat queued it (printed AFTER
#                                       the push, never before)
#   gotabwm: notify paint id=<n>       the toast is ON THE SCANOUT and
#                                       the frame was PRESENTED
#   gotabwm: notify dismiss id=<n>     the toast click took it away and
#                                       focused its sender
#   gotabwm: notify center paint       the history center was presented
#   gotabwm: notify center dismiss    its row control removed one item
#
# The pixel probe is a kind-4 snapshot fired on `notify paint`, not a host
# framebuffer grab: the guest streams its own composed scanout, so the
# pixels ARE the seat's, and the trigger marker is printed after the
# present — a grab keyed on `gotabwm: notify id=` would read a frame the
# seat had not flushed yet (the go-wm-seat run 03 note).
#
# The input is `--input-string $'jck\np'`, NOT `--input-chords`, and the
# difference is load-bearing. GOFILES is a tty app: it reads bytes from its
# bound /dev/tty and decodes them with keys.Decode. An ARROW arrives as a
# single HID usage (0x51/0x52) that the kernel expands into the three tty
# bytes ESC [ B — and over the cv-input transport (0.25 s per stroke) that
# expansion is not atomic: the ESC is delivered and decoded on its own, so
# `keys.Decode` returns KeyEsc and the app runs goUp() instead of moving the
# selection. That is exactly what the first attempt at this run did — the
# app climbed to /host, opened APPS.TXT, and pasted into the share root
# (observed 2026-09-26: `gofiles: cd /host`, `gofiles: view APPS.TXT`,
# `gofiles: paste refused APPS.TXT exists`, and no toast at all). The vi keys
# j/k do the same move WITHOUT a CSI sequence — one printable byte, decoded
# as a rune — so the whole batch is five printable bytes and one Enter:
#
#   j  move down one entry      0 -> 1  (SOURCE.TXT)
#   c  yank a COPY of it        `gofiles: clip copy SOURCE.TXT`
#   k  move up one entry        1 -> 0  (SUB)
#  \n  open the selection       `gofiles: cd /host/NOTIFY/SUB`
#   p  paste                    `gofiles: pasted SOURCE.TXT` + the toast
#
# The first click is a `--pointer-virtio` press+release at the toast's centre,
# (112, 702) = the middle of notifyRect(1280,720,0) = (8, 692, 208, 20). It
# then opens the center from the clock/status panel, selects the sender, and
# presses that row's X control. The sequence is scheduled on the PAINT marker,
# not on the request marker, so the toast is provably on the scanout when the
# first pointer edge arrives. The seat's tick is ~1 s, NotifyTicks is 8, and
# pointer transport paces 2.5 s per message.
#
# exec-order: assert-proven -- the run ends on `rx-gotabwm-notify-ok`, which
# only script3 prints, and script3 is held behind the center's row-dismiss
# marker, which only the seat's notification-center action can print.
# The rms are load-bearing, same as run 16: a SESSION.TABS left by earlier
# legs reexec'd GOCALC+NOTE on this boot, and a NOTIFY.HIST restored one
# stale toast into the center — the scripted (400,227) sender click then
# landed on the STALE row and `notify center focus id=` never printed
# (observed 2026-10-20: `notify history restore n=1`, focus absent).
vgate_file script-06.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm NOTIFY.HIST
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-06.txt <<'EOF'
dui focus 0
exec GOFILES.ELF /host/NOTIFY
EOF

vgate_file script3-06.txt <<'EOF'
wm
dui
echo rx-gotabwm-notify-ok
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio --cvc-snap \
    --snapshot-after 'gotabwm: notify paint id=' \
    --snapshot-out '$RUN_DIR/snap-06' \
    --script '$RUN_DIR/script-06.txt' \
    --script2 '$RUN_DIR/script2-06.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-string $'jck\np' \
    --input-string-after 'gofiles: ready' \
    --pointer-virtio '112,702,d;112,702,u;1198,702,d;1198,702,u;400,227,d;400,227,u;880,227,d;880,227,u' \
    --pointer-virtio-after 'gotabwm: notify paint id=' \
    --script3 '$RUN_DIR/script3-06.txt' \
    --script3-after 'gotabwm: notify center dismiss' \
    --script-expect 'rx-gotabwm-notify-ok' --timeout 360

vgate_assert 06 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 06 serial-contains 'gotabwm: mode live'
vgate_assert 06 serial-absent 'gotabwm: mode demo'
# M104e (#2272): live mode resolves the fonts too — the degrade marker is
# the never-blank contract's evidence (the toast pixels below are the proof
# it still painted).
vgate_assert 06 serial-contains 'gotabwm: fonts '
vgate_assert 06 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 06 serial-contains 'gofiles: declare accepted'
# The adopter's half: the copy completed and the notify was ACCEPTED. The
# refused marker is the control — a seat that never answered would print
# `notify refused` and the chain below would be absent.
vgate_assert 06 serial-contains 'gofiles: cd /host/NOTIFY/SUB'
vgate_assert 06 serial-contains 'gofiles: pasted SOURCE.TXT'
vgate_assert 06 serial-contains 'gofiles: notify sent copied SOURCE.TXT'
vgate_assert 06 serial-absent 'gofiles: notify refused'
# The seat's half: kind 12 was applied, the toast reached the scanout, and
# the click dismissed it.
vgate_assert 06 serial-contains 'gotabwm: notify id='
vgate_assert 06 serial-contains 'copied SOURCE.TXT'
vgate_assert 06 serial-contains 'gotabwm: notify paint id='
vgate_assert 06 serial-contains 'gotabwm: notify dismiss id='
vgate_assert 06 serial-contains 'gotabwm: notify center open'
vgate_assert 06 serial-contains 'gotabwm: notify center paint'
vgate_assert 06 serial-contains 'gotabwm: notify center focus id='
vgate_assert 06 serial-contains 'gotabwm: notify center dismiss'
# Click-to-focus is the whole point of a toast raised by another tab, so the
# focus must be visible in the log: the same `tab focus` / `host focus` pair
# alt-tab and a rail click print.
vgate_assert 06 serial-contains 'gotabwm: tab focus id='
vgate_assert 06 serial-contains 'gotabwm: host focus id='
vgate_assert 06 serial-contains 'rx-gotabwm-notify-ok'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'

# The chain as an ORDERING check, because each of these markers can appear
# without any of the others. Only the CAUSAL orders are asserted: the paste
# that caused the toast, the seat's queue line before the app's ack (the ack
# is the ANSWER to that request, so the app cannot claim the user was told
# before the seat had queued anything), the queue line before the paint (the
# paint marker is printed after the push), and the paint before the dismiss
# (run 06's click is anchored on the paint marker, so the toast was on screen
# before anything dismissed it). One sender id throughout: the toast belongs
# to the tab that raised it.
#
# `sent` and `painted` are deliberately NOT ordered against each other. Both
# are downstream of `queued` with nothing causal in between: the seat prints
# `queued` while servicing the request and paints on the next presented tick,
# while the app prints `sent` when the ack makes the mailbox round trip back.
# Which lands first is a scheduling race. An earlier version of this hook
# asserted sent < painted and failed on a rebuild that changed nothing about
# the chain (observed 2026-09-26: sent=25056 painted=25015) — asserting a
# race is asserting a flake.
vgate_assert 06 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def at(pat, what):
    m = re.search(pat, ser)
    if not m:
        sys.exit("no %s in the serial log" % what)
    return m

pasted = at(r"(?m)^gofiles: pasted SOURCE\.TXT$", "the app's completed copy")
queued = at(r"(?m)^gotabwm: notify id=(\d+) copied SOURCE\.TXT$", "the seat's queue line")
sent = at(r"(?m)^gofiles: notify sent copied SOURCE\.TXT$", "the app's accepted ack")
painted = at(r"(?m)^gotabwm: notify paint id=(\d+)$", "the seat's paint marker")
dismissed = at(r"(?m)^gotabwm: notify dismiss id=(\d+)$", "the click's dismiss marker")
# queued BEFORE sent, not after: the seat prints its line while it services
# the request, and the app's ack can only print once that answer has made
# the mailbox round trip back. Getting this backwards would mean the app
# claimed the user was told before the seat had queued anything.
if not (pasted.start() < queued.start() < sent.start()
        and queued.start() < painted.start() < dismissed.start()):
    sys.exit("notify chain out of order: paste=%d queued=%d sent=%d painted=%d dismissed=%d"
             % (pasted.start(), queued.start(), sent.start(), painted.start(), dismissed.start()))

wid = queued.group(1)
for name, m in (("paint", painted), ("dismiss", dismissed)):
    if m.group(1) != wid:
        sys.exit("the %s marker names id=%s, want the sender id=%s" % (name, m.group(1), wid))

# The message the app printed is byte-for-byte the message the seat queued
# (the `queued` regex above anchors on the full line, so any truncation by
# the 24-byte title budget would have failed to match). "copied SOURCE.TXT"
# is 17 bytes, so nothing was cut.
if len("copied SOURCE.TXT") > 24:
    sys.exit("the adopter's message exceeds the 24-byte title budget")

# The dismiss is the CLICK's, not the NotifyTicks expiry's, and this is the
# one check that tells them apart. Both print the same line — one marker, two
# causes — but only the click path focuses the sender, so the focus pair must
# be the two lines IMMEDIATELY after the dismiss. Searching for the pair on
# its own would not do it: the DECLARE already printed `tab focus id=` for
# this window, so the first occurrence is long before the toast. An expiry
# that fired instead of the click would leave the pair absent here.
lines = ser.split("\n")
hits = [k for k, l in enumerate(lines) if l == "gotabwm: notify dismiss id=" + wid]
if not hits:
    sys.exit("no dismiss line for id=%s" % wid)
i = hits[0]
if lines[i + 1] != "gotabwm: tab focus id=" + wid or lines[i + 2] != "gotabwm: host focus id=" + wid:
    sys.exit("the dismiss at line %d is not the click's: followed by %r / %r, want the focus pair"
             % (i, lines[i + 1][:44], lines[i + 2][:44]))
print("M79k notify chain OK: paste -> seat queue (id=%s) + app ack + paint -> CLICK dismiss -> focus"
      % wid)
PY

# THE pixel assert: the toast on the scanout, read out of the guest's own
# composed frame. The panel is notifyRect(1280,720,0,1) = (8, 692, 208, 20): a
# 2px accent rule down the left edge, the 8x8 face text, and Surface between
# them. Tokens are the dark palette's Accent 0x3b82f6, Surface 0x222d35, Ink
# 0xe6edf3. The snapshot is raw BGRX at the scanout's own resolution.
vgate_assert 06 snapshot 'snap-06-*.raw' <<'PY'
import sys
from collections import Counter

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)" % (len(raw), need, W, H))

def px(x, y):
    off = (y * W + x) * 4
    b, g, r = raw[off], raw[off + 1], raw[off + 2]
    return (r, g, b)

# The toast rect, and the seat chrome it must NOT have eaten: the 22px top
# rail, and the bottom-right clock panel chromeRect(1280,720) = (1124, 692).
TX, TY, TW, TH = 8, 692, 208, 20
CX, CY, CW, CH = 1124, 692, 148, 20
if TX + TW > CX:
    sys.exit("the toast rect and the clock panel overlap; the layout pin is wrong")
if TY < 22:
    sys.exit("the toast rect starts inside the 22px rail; the layout pin is wrong")

ACCENT = (0x3b, 0x82, 0xf6)
SURFACE = (0x22, 0x2d, 0x35)
INK = (0xe6, 0xed, 0xf3)
CHROME_BG = (0x11, 0x17, 0x1c)

BORDER = (0x33, 0x41, 0x55)

modal = Counter()
ink = surface = 0
for y in range(TY, TY + TH):
    for x in range(TX, TX + TW):
        c = px(x, y)
        modal[c] += 1
        if c == INK:
            ink += 1
        elif c == SURFACE:
            surface += 1

best, n = modal.most_common(1)[0]
print("toast rect (%d,%d %dx%d): modal=#%02x%02x%02x n=%d distinct=%d "
      "ink=%d surface=%d"
      % (TX, TY, TW, TH, best[0], best[1], best[2], n, len(modal), ink, surface))

# M104e: the accent rule rides the plate's ROUNDED left edge — the §2.2
# radius is the visible claim, the exact-token probes the raw scanout
# permits. On the straight section the outermost column is the 1px Border
# stroke and column TX+1 is the accent rule; the corner pixels are outside
# the silhouette (the §2.5 shadow / the client beneath), so they can never
# read accent — a square plate painted accent at every row of both columns.
assert px(TX + 1, TY + TH // 2) == ACCENT, \
    "no accent rule at the toast's left edge mid-height"
assert px(TX, TY + TH // 2) == BORDER, \
    "the plate's 1px Border stroke is missing at the left edge"
assert px(TX + 2, TY + TH // 2) == SURFACE, \
    "the toast's interior is not Surface past the rule"
for cx, cy in ((TX, TY), (TX, TY + TH - 1), (TX + TW - 1, TY), (TX + TW - 1, TY + TH - 1)):
    assert px(cx, cy) != ACCENT, \
        "corner %d,%d reads accent - the toast plate is not rounded" % (cx, cy)
assert px(TX + 1, TY) != ACCENT and px(TX + 1, TY + TH - 1) != ACCENT, \
    "the accent rule reaches the corner rows - the left edge is not rounded"
# The face painted, in ink, inside the panel and clear of the rule.
assert ink >= 20, ("only %d ink pixels in the toast rect - the message text did not paint" % ink)
# And the panel is Surface, NOT the blank desktop Bg (0x182026): a toast that
# blended into the background would be invisible and still "painted".
assert best == SURFACE, ("the toast rect's modal colour is #%02x%02x%02x, want the "
                         "Surface token #%02x%02x%02x - the panel is not a toast"
                         % (best + SURFACE))
assert surface >= n // 2, ("only %d of %d modal pixels read Surface" % (surface, n))

# The clock panel is still ITS OWN chrome: the toast did not overpaint it.
clock = Counter(px(x, y) for y in range(CY, CY + CH) for x in range(CX, CX + CW))
cbest, cn = clock.most_common(1)[0]
assert cbest == CHROME_BG, ("the clock panel reads #%02x%02x%02x, want the ChromeBg "
                            "token #%02x%02x%02x - the toast overpainted it"
                            % (cbest + CHROME_BG))

# The RAIL is deliberately NOT probed for colour here: the rail paints the
# Accent token itself (a focused cell's underline), so an accent count in the
# top 22 rows measures the rail, not the toast. What the layout pin at the
# top of this hook already proves is the real claim: the toast rect starts
# below the 22px rail and ends before the clock panel, so nothing it paints
# can land on either.
print("toast: ink=%d surface=%d; clock panel intact at #%02x%02x%02x (n=%d)"
      % (ink, surface, cbest[0], cbest[1], cbest[2], cn))
PY

# --- M83f (#1779) run 07: seat-owned presence, never a waited-out minute ---
# The monitor persists idle_minutes=1 and seeds a gate-only threshold of
# two composite ticks per minute. The production minute is 60 ticks, and a
# normal share has no GOTABWM.IDLE.TEST. Dim at tick 2, curtain at tick 4;
# one pointer event wakes. The seat announces transitions only AFTER a
# successful present. A kind-4 snapshot probes the curtain on the scanout.
# `vf rm SESSION.TABS` keeps earlier legs' session rows from reexec'ing
# three client tabs into a leg whose timing is measured in single ticks.
vgate_file script-07.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
settings set idle_minutes 1
write GOTABWM.IDLE.TEST 2
set GOMAXPROCS=1
exec GOTABWM.ELF
EOF

vgate_file script2-07.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-07.txt <<'EOF'
kill GOTABWM.ELF
echo rx-gotabwm-idle-ok
EOF

vgate_run 07 -- \
    --screen '$RUN_DIR/screen-07' \
    --via-virtio --cvc-snap \
    --snapshot-after 'gotabwm: idle lock' \
    --snapshot-out '$RUN_DIR/snap-idle' \
    --script '$RUN_DIR/script-07.txt' \
    --script2 '$RUN_DIR/script2-07.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '600,360,d;600,360,u' \
    --pointer-virtio-after 'gotabwm: idle lock' \
    --script3 '$RUN_DIR/script3-07.txt' \
    --script3-after 'gotabwm: idle wake' \
    --script-expect 'rx-gotabwm-idle-ok' --timeout 300

vgate_assert 07 serial-contains 'settings: idle_minutes=1 (persisted)'
vgate_assert 07 serial-contains 'gotabwm: idle thresholds dim=2 lock=4'
vgate_assert 07 serial-contains 'gotabwm: idle dim'
vgate_assert 07 serial-contains 'gotabwm: idle lock'
vgate_assert 07 serial-contains 'gotabwm: idle wake'
vgate_assert 07 serial-contains 'rx-gotabwm-idle-ok'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'exited status=139'
vgate_assert 07 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
names = ["gotabwm: idle thresholds dim=2 lock=4", "gotabwm: idle dim",
         "gotabwm: idle lock", "gotabwm: ptr", "gotabwm: idle wake",
         "rx-gotabwm-idle-ok"]
positions = [ser.find(name) for name in names]
if any(p < 0 for p in positions) or positions != sorted(positions):
    sys.exit("seat presence order: " + repr(list(zip(names, positions))))
print("seeded thresholds -> presented dim -> presented curtain -> input -> presented wake")
PY

# Full-frame cover, centred Surface panel, accent rule, and actual text ink.
# The top-left is ChromeBg, not the bright underlying desktop; the panel
# text is the seat's explicit NOT AUTHENTICATION notice (unit-pinned).
# M104e: the plate is rounded — its corner pixel is the curtain's own
# ChromeBg cover (outside the silhouette), the 2px accent rule rides the
# straight left edge, and Surface fills the interior from column x+2.
vgate_assert 07 snapshot 'snap-idle-0.raw' <<'PY'
import sys
from collections import Counter
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W*H*4:
    sys.exit("no full BGRX scanout in idle snapshot")
def px(x, y):
    i = (y*W+x)*4
    return tuple(raw[i+2-j] for j in range(3))
bg = (0x11, 0x17, 0x1c)
surface = (0x22, 0x2d, 0x35)
accent = (0x3b, 0x82, 0xf6)
x, y = (W-256)//2, (H-64)//2
if px(40, 40) != bg or px(W-40, H-40) != bg:
    sys.exit("curtain does not cover the full scanout")
if px(x, y) != bg:
    sys.exit("the curtain plate's top-left corner is painted - not rounded")
if px(x, y+32) != accent or px(x+1, y+32) != accent:
    sys.exit("no accent rule on the curtain plate's left edge")
if px(x+2, y+32) != surface or px(x+128, y+32) != surface:
    sys.exit("the curtain plate's interior is not Surface")
colours = Counter(px(col, row) for row in range(y+8, y+40)
                  for col in range(x+10, x+240))
ink = sum(n for c, n in colours.items() if min(c) >= 150)
if ink < 20:
    sys.exit("curtain's honesty text did not paint (%d ink pixels)" % ink)
print("curtain covers full frame; panel accent and honesty text painted (ink=%d)" % ink)
PY

# --- M99d (#2182) run 08: an audible toast + the GOSET volume row ----------
#
# The chain this run proves has four links, each independently checkable:
#
#   gotabwm: notify-sound volume=25     the seat re-applied the persisted
#                                        audio_volume row to slot 44 at boot
#                                        (the kernel's gain boots at 100 and
#                                        never reads the file, so the seat is
#                                        the consumer)
#   gotabwm: notify-sound ready         the one-time AudioQuery succeeded and
#     bytes=N fmt=.. rate=.. ch=..       the chime was synthesized for the
#                                        negotiated tuple — never probed again
#   sound: vol=40                        the KERNEL's own report after GOSET's
#                                        typed `audio_volume=40` line landed
#                                        on slot 44 through the normal
#                                        set+save path
#   gotabwm: notify-sound played        the toast's chime drained through the
#     bytes=N completed=N                mix; `completed` is the kernel's own
#                                        counter, printed on the composite
#                                        tick AFTER the bounded play call
#
# The chime is an M99b vi.AudioStream client (open, prefill inside the
# per-source queue, start, end) — never the blocking slot-43 drain, which the
# kernel's own `43 sys_audio_play` counter would expose because stream ops
# and legacy plays share the slot.
#
# The inputs use the two proven transports deliberately: GOSET's typed line
# rides --input-chords (the go-wm-default keyboard_layout pattern) after
# `goset: ready `, and GOFILES's copy+notify batch rides --input-string (the
# run 06 pattern — printable runes, no CSI expansion) after `gofiles: ready`.
# The `sound` report is forwarded the moment GOSET's `saved` marker lands, so
# `sound: vol=40` is read after the apply but before GOFILES ever execs.
vgate_file script-08.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm NOTIFY/SUB/SOURCE.TXT
set GOMAXPROCS=1
settings set notify_dnd off
settings set notify_sound on
settings set audio_volume 25
exec GOTABWM.ELF
EOF

vgate_file script2-08.txt <<'EOF'
dui focus 0
exec GOSET.ELF
EOF

vgate_file script3-08.txt <<'EOF'
sound
exec GOFILES.ELF /host/NOTIFY
EOF

vgate_run 08 -- \
    --screen '$RUN_DIR/screen-08' \
    --via-virtio \
    --sound \
    --script '$RUN_DIR/script-08.txt' \
    --script2 '$RUN_DIR/script2-08.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'a,u,d,i,o,_,v,o,l,u,m,e,=,4,0,return' \
    --input-chords-after 'goset: ready ' \
    --script3 '$RUN_DIR/script3-08.txt' \
    --script3-after 'goset: saved ' \
    --input-string $'jck\np' \
    --input-string-after 'gofiles: ready' \
    --script-expect 'gotabwm: notify-sound played' --timeout 300

# Flake note (observed 2026-10-20, two runs): this leg is only as
# reliable as the host's audio device. (a) The `played` marker is
# drain-paced — `completed` only reaches `bytes` after the virtio-snd
# tx path empties the prefill, and a slow device can push the marker
# near the 300 s window. (b) The device can also STALL mid-run: the
# `sound` report then shows `fail_stage=3` with `spins=` at the tx
# budget (60M observed — the used ring stopped completing, vs
# fail_stage=0 on a healthy boot), the bounded Submit refuses, and the
# seat honestly counts `notify-sound skipped total=1` instead of
# `played`. Both are device/transport pacing, not seat logic — read the
# serial's `completed=`/`fail_stage=`/`skipped` lines before calling a
# red leg a regression.

vgate_assert 08 serial-contains 'settings: notify_dnd=off (persisted)'
vgate_assert 08 serial-contains 'settings: notify_sound=on (persisted)'
vgate_assert 08 serial-contains 'settings: audio_volume=25 (persisted)'
vgate_assert 08 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 08 serial-contains 'gotabwm: mode live'
# The seat's startup sound contract: the persisted row re-applied to slot 44,
# then the one probe and the one synthesis — in that order, once each.
vgate_assert 08 serial-contains 'gotabwm: notify-sound volume=25'
vgate_assert 08 serial-contains 'gotabwm: notify-sound ready bytes='
vgate_assert 08 serial-absent 'gotabwm: notify-sound off'
vgate_assert 08 serial-absent 'gotabwm: notify-sound unavailable'
# The panel's half of the volume control: the typed row set, saved, and the
# kernel's OWN report shows the gain the slot-44 call left behind.
vgate_assert 08 serial-contains 'exec: loaded GOSET.ELF'
vgate_assert 08 serial-contains 'goset: ready keys='
vgate_assert 08 serial-contains 'goset: set audio_volume=40'
vgate_assert 08 serial-contains 'goset: saved keys='
vgate_assert 08 serial-contains 'sound: vol=40'
# And the toast is still a toast: the same notify/paint chain run 06 proved,
# now with its chime confirmed drained by the kernel's own counter.
vgate_assert 08 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 08 serial-contains 'gofiles: pasted SOURCE.TXT'
vgate_assert 08 serial-contains 'gofiles: notify sent copied SOURCE.TXT'
vgate_assert 08 serial-contains 'gotabwm: notify id='
vgate_assert 08 serial-contains 'gotabwm: notify paint id='
vgate_assert 08 serial-contains 'gotabwm: notify-sound played bytes='
vgate_assert 08 serial-absent 'gotabwm: notify-sound skipped'
vgate_assert 08 serial-absent 'gofiles: notify refused'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-absent 'exited status=139'

# The chain as an arithmetic + ordering check. `played bytes` must equal both
# the synthesized length from `ready` and the kernel's `completed` counter —
# a partial drain or a marker printed ahead of the truth fails here, and the
# causal order (row applied, chime built, toast queued, drain confirmed) is
# pinned because every one of these markers can appear without the others.
vgate_assert 08 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def at(pat, what):
    m = re.search(pat, ser)
    if not m:
        sys.exit("no %s in the serial log" % what)
    return m

volume = at(r"(?m)^gotabwm: notify-sound volume=(\d+)$", "the boot volume re-apply")
ready = at(r"(?m)^gotabwm: notify-sound ready bytes=(\d+) fmt=(\d+) rate=(\d+) ch=(\d+)$",
           "the synthesized chime")
queued = at(r"(?m)^gotabwm: notify id=(\d+) copied SOURCE\.TXT$", "the toast's queue line")
vol40 = at(r"(?m)^sound: vol=40", "the kernel's own volume report")
played = at(r"(?m)^gotabwm: notify-sound played bytes=(\d+) completed=(\d+)$",
            "the drain confirmation")

if not (volume.start() < ready.start() < queued.start() < played.start()):
    sys.exit("sound chain out of order: volume=%d ready=%d queued=%d played=%d"
             % (volume.start(), ready.start(), queued.start(), played.start()))
# GOSET's apply landed before the `sound` report was forwarded (script3 waits
# on `goset: saved`, which prints after the set), and the toast's chime came
# after both — the volume the chime drained at was GOSET's, not the boot row's.
if not (at(r"goset: set audio_volume=40", "the panel's set").start()
        < vol40.start() < queued.start()):
    sys.exit("volume chain out of order: the kernel report must sit between "
             "the panel's set and the toast")

# The kernel's counters are the honest arithmetic: the chime the seat built
# is the chime the device confirmed, byte for byte.
chime = int(ready.group(1))
if chime <= 0 or chime > 4 * 4096:
    sys.exit("chime length %d outside the stream prefill bound (4 x 4096)" % chime)
if int(played.group(1)) != chime:
    sys.exit("played bytes=%s, want the synthesized %d" % (played.group(1), chime))
if int(played.group(2)) != chime:
    sys.exit("the kernel confirmed %s of %d chime bytes" % (played.group(2), chime))
print("M99d sound chain OK: volume -> ready (%dB fmt=%s rate=%s ch=%s) -> "
      "set vol=40 -> toast -> played completed=%s"
      % (chime, ready.group(2), ready.group(3), ready.group(4), played.group(2)))
PY

# --- M99d (#2182) run 09: DND holds the notice, so nothing ever plays ------
#
# `settings set notify_dnd on` is persisted before the exec, so the seat's
# boot applies it (`notify dnd=on via=boot`) and the notice lands in the
# center history with `notify held id=` — accepted, never toasted, never
# chimed. The kernel's `43 sys_audio_play calls=0` is the load-bearing
# absent: every audio call — a stream open AND a legacy play — shares slot
# 43, so a seat that secretly probed a chime for the held notice cannot hide
# behind a missing marker. The `ready` line still prints: DND gates the
# PLAY, not the one-time device configuration.
vgate_file script-09.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm NOTIFY/SUB/SOURCE.TXT
set GOMAXPROCS=1
settings set notify_dnd on
settings set notify_sound on
exec GOTABWM.ELF
EOF

vgate_file script2-09.txt <<'EOF'
dui focus 0
exec GOFILES.ELF /host/NOTIFY
EOF

vgate_file script3-09.txt <<'EOF'
syscalls
echo rx-gotabwm-snd-dnd-ok
EOF

vgate_run 09 -- \
    --screen '$RUN_DIR/screen-09' \
    --via-virtio \
    --sound \
    --script '$RUN_DIR/script-09.txt' \
    --script2 '$RUN_DIR/script2-09.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-string $'jck\np' \
    --input-string-after 'gofiles: ready' \
    --script3 '$RUN_DIR/script3-09.txt' \
    --script3-after 'gofiles: notify sent copied SOURCE.TXT' \
    --script-expect 'rx-gotabwm-snd-dnd-ok' --script-expect-tail 4 --timeout 300

vgate_assert 09 serial-contains 'settings: notify_dnd=on (persisted)'
vgate_assert 09 serial-contains 'gotabwm: notify dnd=on via=boot'
vgate_assert 09 serial-contains 'gotabwm: notify-sound ready bytes='
vgate_assert 09 serial-contains 'gofiles: notify sent copied SOURCE.TXT'
vgate_assert 09 serial-absent 'gofiles: notify refused'
# Held is the whole point: the notice is in the center, the toast was never
# queued, and the chime was never touched.
vgate_assert 09 serial-contains 'gotabwm: notify held id='
vgate_assert 09 serial-absent 'gotabwm: notify id='
vgate_assert 09 serial-absent 'gotabwm: notify paint id='
vgate_assert 09 serial-absent 'gotabwm: notify-sound played'
vgate_assert 09 serial-absent 'gotabwm: notify-sound skipped'
# The kernel's own counters, forwarded AFTER the held notice: one probe at
# boot, zero audio-path calls for the whole run.
vgate_assert 09 serial-contains '42 sys_audio_info calls=1'
vgate_assert 09 serial-contains '43 sys_audio_play calls=0'
vgate_assert 09 serial-contains 'rx-gotabwm-snd-dnd-ok'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 serial-absent 'exited status=139'

# --- M99d (#2182) run 10: notify_sound=off — the toast without the chime ---
#
# The policy row is persisted `off` before the exec, so the boot prints
# `notify-sound off` and never probes at all — `42 sys_audio_info calls=0`
# is that fact observed in the kernel's counter, not inferred from a missing
# marker. The toast itself is unchanged: queued, painted, and dismissed by
# the NotifyTicks expiry, which is also why script3 waits for the dismiss —
# the run ends only after the toast's FULL lifetime passed silently.
vgate_file script-10.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm NOTIFY/SUB/SOURCE.TXT
set GOMAXPROCS=1
settings set notify_dnd off
settings set notify_sound off
exec GOTABWM.ELF
EOF

vgate_file script2-10.txt <<'EOF'
dui focus 0
exec GOFILES.ELF /host/NOTIFY
EOF

vgate_file script3-10.txt <<'EOF'
syscalls
echo rx-gotabwm-snd-off-ok
EOF

vgate_run 10 -- \
    --screen '$RUN_DIR/screen-10' \
    --via-virtio \
    --sound \
    --script '$RUN_DIR/script-10.txt' \
    --script2 '$RUN_DIR/script2-10.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-string $'jck\np' \
    --input-string-after 'gofiles: ready' \
    --script3 '$RUN_DIR/script3-10.txt' \
    --script3-after 'gotabwm: notify dismiss id=' \
    --script-expect 'rx-gotabwm-snd-off-ok' --timeout 300

vgate_assert 10 serial-contains 'settings: notify_sound=off (persisted)'
vgate_assert 10 serial-exact 'gotabwm: notify-sound off' 1
vgate_assert 10 serial-contains 'gofiles: notify sent copied SOURCE.TXT'
vgate_assert 10 serial-contains 'gotabwm: notify id='
vgate_assert 10 serial-contains 'gotabwm: notify paint id='
vgate_assert 10 serial-contains 'gotabwm: notify dismiss id='
vgate_assert 10 serial-absent 'gotabwm: notify-sound ready'
vgate_assert 10 serial-absent 'gotabwm: notify-sound played'
vgate_assert 10 serial-absent 'gotabwm: notify-sound skipped'
vgate_assert 10 serial-absent 'gotabwm: notify-sound unavailable'
# Off means never probed: zero info calls, zero audio-path calls.
vgate_assert 10 serial-contains '42 sys_audio_info calls=0'
vgate_assert 10 serial-contains '43 sys_audio_play calls=0'
vgate_assert 10 serial-contains 'rx-gotabwm-snd-off-ok'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 serial-absent 'exited status=139'

# --- M99d (#2182) run 11: no sound device — the toast without the VM flag --
#
# Same run as 10 minus --sound: AudioQuery reports no usable device once at
# boot, the seat prints `unavailable` exactly once (serial-exact pins the
# one-probe contract — no per-toast ENXIO probing), and the toast lifecycle
# is byte-for-byte the armed case. `42 sys_audio_info calls=1` +
# `43 sys_audio_play calls=0` is the kernel's own accounting of it.
vgate_file script-11.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm NOTIFY/SUB/SOURCE.TXT
set GOMAXPROCS=1
settings set notify_dnd off
settings set notify_sound on
exec GOTABWM.ELF
EOF

vgate_file script2-11.txt <<'EOF'
dui focus 0
exec GOFILES.ELF /host/NOTIFY
EOF

vgate_file script3-11.txt <<'EOF'
syscalls
echo rx-gotabwm-snd-nodev-ok
EOF

vgate_run 11 -- \
    --screen '$RUN_DIR/screen-11' \
    --via-virtio \
    --script '$RUN_DIR/script-11.txt' \
    --script2 '$RUN_DIR/script2-11.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-string $'jck\np' \
    --input-string-after 'gofiles: ready' \
    --script3 '$RUN_DIR/script3-11.txt' \
    --script3-after 'gotabwm: notify dismiss id=' \
    --script-expect 'rx-gotabwm-snd-nodev-ok' --timeout 300

vgate_assert 11 serial-exact 'gotabwm: notify-sound unavailable' 1
vgate_assert 11 serial-contains 'gofiles: notify sent copied SOURCE.TXT'
vgate_assert 11 serial-contains 'gotabwm: notify id='
vgate_assert 11 serial-contains 'gotabwm: notify paint id='
vgate_assert 11 serial-contains 'gotabwm: notify dismiss id='
vgate_assert 11 serial-absent 'gotabwm: notify-sound ready'
vgate_assert 11 serial-absent 'gotabwm: notify-sound played'
vgate_assert 11 serial-absent 'gotabwm: notify-sound skipped'
# One probe, no play attempts, and no ENXIO line anywhere — the seat's own
# output stays clean of the error the card forbids it to leak.
vgate_assert 11 serial-contains '42 sys_audio_info calls=1'
vgate_assert 11 serial-contains '43 sys_audio_play calls=0'
vgate_assert 11 serial-absent 'ENXIO'
vgate_assert 11 serial-contains 'rx-gotabwm-snd-nodev-ok'
vgate_assert 11 serial-absent 'gotabwm: agent'
vgate_assert 11 serial-absent '[EXC] parking:'
vgate_assert 11 serial-absent 'exited status=139'

# --- M109e (#2401) run 12: the agent indicator + milestone notify lanes ---
#
# The armed share names GOTABWM.ELF on the agent-hmac allowlist, so the
# seat holds the receipt key and only MAC-verified RCPT-* files can move
# its chrome. The choreography:
#
#   gotabwm: agent watch             armed at init — the flag flipped on
#   gotabwm: agent verb fs.read      the boot backlog replayed
#   gotabwm: agent caught n=1 bad=0  the catch-up is DONE — script3's
#                                     anchor: everything it publishes is
#                                     a live receipt, toastable
#   vf mv AGENT/STAGED/R* -> AUDIT/  the lane's own publish shape lands
#                                     all five receipts inside one poll
#   gotabwm: agent session open      the indicator turns on (badge in
#   agent=devin                       the clock panel's badge row)
#   gotabwm: agent milestone <name>  commit / push / install, each from a
#   gotabwm: notify id=0 agent: ...  verified ok+exit-0 gosh.run receipt,
#                                     toasted through the ordinary
#                                     kind-12 path — strip, center,
#                                     notify-out lane, chime policy
#   gotabwm: agent rcpt bad          the forged close: named once, no
#                                     close marker, badge stays on
#   gotabwm: notify paint id=0       the toasts are on the scanout — the
#                                     snapshot reads badge + strip off
#                                     the guest's own composed frame
vgate_file script-12.txt <<'EOF'
set GOMAXPROCS=1
exec GOTABWM.ELF
EOF

vgate_file script2-12.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-12.txt <<'EOF'
vf mv AGENT/STAGED/R1 AGENT/AUDIT/RCPT-b0000001-00000002
vf mv AGENT/STAGED/R2 AGENT/AUDIT/RCPT-b0000001-00000003
vf mv AGENT/STAGED/R3 AGENT/AUDIT/RCPT-b0000001-00000004
vf mv AGENT/STAGED/R4 AGENT/AUDIT/RCPT-b0000001-00000005
vf mv AGENT/STAGED/R5 AGENT/AUDIT/RCPT-b0000001-00000006
echo rx-gotabwm-agent-ok
EOF

vgate_run 12 -- \
    --cvc-file '$RUN_DIR/agent-share' \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-after 'gotabwm: notify paint id=' \
    --snapshot-out '$RUN_DIR/snap-12' \
    --script '$RUN_DIR/script-12.txt' \
    --script2 '$RUN_DIR/script2-12.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-12.txt' \
    --script3-after 'gotabwm: agent caught ' \
    --script-expect 'gotabwm: notify paint id=' --timeout 300

vgate_assert 12 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 12 serial-contains 'gotabwm: mode live'
# The armed marker is the flag flip; the catch-up replayed the backlog
# fs.read by name before script3's publishes could land.
vgate_assert 12 serial-contains 'gotabwm: agent watch'
vgate_assert 12 serial-contains 'gotabwm: agent verb fs.read'
vgate_assert 12 serial-contains 'gotabwm: agent caught n=1 bad=0'
# The live burst: indicator on, three milestones toasted, the forged
# close refused by name — and it printed no close marker and took
# nothing down.
vgate_assert 12 serial-contains 'gotabwm: agent session open agent=devin'
vgate_assert 12 serial-contains 'gotabwm: agent milestone commit'
vgate_assert 12 serial-contains 'gotabwm: agent milestone push'
vgate_assert 12 serial-contains 'gotabwm: agent milestone install'
vgate_assert 12 serial-contains 'gotabwm: notify id=0 agent: commit ok'
vgate_assert 12 serial-contains 'gotabwm: notify id=0 agent: push ok'
vgate_assert 12 serial-contains 'gotabwm: notify id=0 agent: install ok'
vgate_assert 12 serial-contains 'gotabwm: notify paint id=0'
vgate_assert 12 serial-contains 'gotabwm: agent rcpt bad RCPT-b0000001-00000006'
vgate_assert 12 serial-absent 'gotabwm: agent session close'
vgate_assert 12 serial-contains 'rx-gotabwm-agent-ok'
vgate_assert 12 serial-absent '[EXC] parking:'
vgate_assert 12 serial-absent 'exited status=139'

# The publishes landed in the lane itself — the same AUDIT directory the
# daemon writes (the alt share is this run's --cvc-file, not the seeded
# share the share-* asserts read).
vgate_assert 12 python <<'PY'
import os, sys
alt = os.path.join(os.environ["RUN_DIR"], "agent-share")
dst = os.path.join(alt, "AGENT", "AUDIT", "RCPT-b0000001-00000002")
try:
    body = open(dst, "rb").read()
except OSError:
    sys.exit("the published open receipt is not in AGENT/AUDIT")
if b'"event":"open"' not in body:
    sys.exit("the published file is not the session-open receipt")
staged = os.path.join(alt, "AGENT", "STAGED")
left = [n for n in os.listdir(staged) if n.startswith("R")]
if left:
    sys.exit("unconsumed staged receipts remain: %r" % left)
print("all five staged receipts published into AGENT/AUDIT")
PY

# The causal order is the whole chain: armed -> caught-up -> live open ->
# milestones -> forged refusal -> the presented frame that carries them.
vgate_assert 12 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
names = ["gotabwm: agent watch", "gotabwm: agent caught n=1 bad=0",
         "gotabwm: agent session open agent=devin",
         "gotabwm: agent milestone commit", "gotabwm: agent milestone push",
         "gotabwm: agent milestone install",
         "gotabwm: agent rcpt bad RCPT-b0000001-00000006",
         "gotabwm: notify paint id=0"]
positions = [ser.find(name) for name in names]
if any(p < 0 for p in positions) or positions != sorted(positions):
    sys.exit("agent-watch order: " + repr(list(zip(names, positions))))
print("agent watch chain OK: armed -> caught -> open -> commit/push/install "
      "-> forged refused -> presented")
PY

# The pixel proof, on the guest's own composed frame: the AGENT badge in
# the clock panel's badge row reads Accent (nothing else in that zone is
# accent — the panel's accent rule is its left edge, outside the probe),
# and the bottom toast panel is Surface with its own rule + ink. The
# badge sits at the panel's right edge: chromeRect is (1124,692,148,20),
# the badge row ends at 1124+148-6=1266, and AGENT is 5 cells x 8px in
# the bitmap face = [1226,1266) x [698,706).
vgate_assert 12 snapshot 'snap-12-*.raw' <<'PY'
import sys
from collections import Counter
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("no full BGRX scanout in the agent snapshot")
def px(x, y):
    i = (y * W + x) * 4
    return raw[i + 2], raw[i + 1], raw[i]
ACCENT = (0x3b, 0x82, 0xf6)
SURFACE = (0x22, 0x2d, 0x35)
INK = (0xe6, 0xed, 0xf3)
accent = 0
for y in range(698, 706):
    for x in range(1226, 1266):
        r, g, b = px(x, y)
        if b > 150 and b > r + 40 and b > g + 40:
            accent += 1
if accent < 20:
    sys.exit("only %d accent pixels in the badge zone — the AGENT tag did "
             "not paint while the session was open" % accent)
modal = Counter(px(x, y) for y in range(692, 712) for x in range(8, 216))
best, n = modal.most_common(1)[0]
if best != SURFACE:
    sys.exit("the bottom toast rect's modal colour is #%02x%02x%02x, want "
             "Surface — no toast on the scanout" % best)
ink = modal.get(INK, 0)
if ink < 20:
    sys.exit("only %d ink pixels in the toast rect — the milestone text did "
             "not paint" % ink)
print("agent badge accent px=%d; toast modal=Surface n=%d ink=%d"
      % (accent, n, ink))
PY

# --- M109e (#2401) run 13: the session close takes the badge back down ---
#
# Same armed share shape; the open is boot backlog so the catch-up itself
# lights the indicator, then the close publishes live — one marker for
# each transition.
vgate_file script-13.txt <<'EOF'
set GOMAXPROCS=1
exec GOTABWM.ELF
EOF

vgate_file script2-13.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-13.txt <<'EOF'
vf mv AGENT/STAGED/R2 AGENT/AUDIT/RCPT-b0000001-00000002
echo rx-gotabwm-close-ok
EOF

vgate_run 13 -- \
    --cvc-file '$RUN_DIR/agent-close-share' \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script-13.txt' \
    --script2 '$RUN_DIR/script2-13.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-13.txt' \
    --script3-after 'gotabwm: agent caught ' \
    --script-expect 'gotabwm: agent session close ' --timeout 300

vgate_assert 13 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 13 serial-contains 'gotabwm: agent watch'
vgate_assert 13 serial-contains 'gotabwm: agent session open agent=devin'
vgate_assert 13 serial-contains 'gotabwm: agent caught n=1 bad=0'
vgate_assert 13 serial-contains 'gotabwm: agent session close agent=devin'
vgate_assert 13 serial-contains 'rx-gotabwm-close-ok'
vgate_assert 13 serial-absent '[EXC] parking:'
vgate_assert 13 serial-absent 'exited status=139'

vgate_assert 13 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
o = ser.find("gotabwm: agent session open agent=devin")
c = ser.find("gotabwm: agent caught n=1 bad=0")
x = ser.find("gotabwm: agent session close agent=devin")
if not (0 <= o < c < x):
    sys.exit("session transitions out of order: open=%d caught=%d close=%d"
             % (o, c, x))
print("catch-up lit the badge from backlog, the live close took it down")
PY

# --- M109e (#2401) run 14: flags-off is byte-silent ---------------------
#
# The strongest off-posture there is: the receipts are REAL (valid MACs
# under the same pinned key) and the agent-hmac row EXISTS — it simply
# does not name the seat. The watch's probe comes back unserved, so the
# boot never prints a line: not the armed marker, not the catch-up, not
# a verb line, nothing. `gotabwm: tick` counted proves the composite
# loop — and therefore the would-be poll — actually ran with the data
# sitting right there.
vgate_file script-14.txt <<'EOF'
set GOMAXPROCS=1
exec GOTABWM.ELF
EOF

vgate_file script2-14.txt <<'EOF'
dui focus 0
EOF

vgate_file script3-14.txt <<'EOF'
echo rx-gotabwm-off-ok
EOF

vgate_run 14 -- \
    --cvc-file '$RUN_DIR/agent-off-share' \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script-14.txt' \
    --script2 '$RUN_DIR/script2-14.txt' \
    --script2-after 'gotabwm: win focus' \
    --script3 '$RUN_DIR/script3-14.txt' \
    --script3-after 'gotabwm: tick' --script3-delay 12 \
    --script-expect 'rx-gotabwm-off-ok' --timeout 300

vgate_assert 14 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 14 serial-contains 'gotabwm: mode live'
vgate_assert 14 serial-count 'gotabwm: tick' 8
# The byte-silence contract: a dozen polls over real, verifiable
# receipts and not one agent line — the row was never served to the seat.
vgate_assert 14 serial-absent 'gotabwm: agent'
vgate_assert 14 serial-contains 'rx-gotabwm-off-ok'
vgate_assert 14 serial-absent '[EXC] parking:'
vgate_assert 14 serial-absent 'exited status=139'


# --- M121a (#2564) run 15: the seat-owned command palette -----------------
#
# ctrl+shift+p is the palette's summon chord — the seat row this card gave
# it in the chords registry (pin, its previous owner, is re-homed on
# ctrl-shift-n). The palette is the launcher's second face over the same
# docked strip: type-to-filter over open tabs, the recent-file log,
# settings keys, the help bundle and the chord registry, ranked by the
# launcher's subsequence matcher.
#
# LIVE seat (vf rm GOTABWM.DEMO — the run 05/09 pattern) so no bounded
# choreography races the legs. GOEDIT hosts first: it is the tab the
# 'edit' leg focuses. Both legs ride ONE chord batch at the fixed
# 0.25 s/stroke pacing:
#
#   ctrl-shift-p,e,d,i,t,return   'edit' -> the Edit tab row -> focus it
#   ctrl-shift-p,s,e,t,t,return   'sett' -> a Settings row -> exec GOSET
#
# Leg order is deliberate: the focus leg needs only the already-hosted
# Edit tab, and 'goset: declare accepted' — script3's anchor — can only
# land AFTER 'palette exec GOSET.ELF' (the exec precedes the declare), so
# the run's end gate can never outrun either leg.
#
# The `vf rm GOTABWM.IDLE.TEST` + `settings set idle_minutes 120` pair is
# load-bearing: run 07 persists idle_minutes=1 and seeds the 2-ticks/min
# fixture on this same share, which leaves dim=2/lock=4 in force — every
# later stroke is then eaten as an idle WAKE rather than reaching the
# palette (observed 2026-10-18: the whole chord batch woke the curtain
# per-stroke and leaked 'edit\nsett\n' into GOEDIT's buffer). The reset
# returns the idle policy to a horizon the chord batch cannot reach.
vgate_file script-15.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm GOTABWM.IDLE.TEST
settings set idle_minutes 120
wm
exec GOTABWM.ELF
EOF

vgate_file script2-15.txt <<'EOF'
dui focus 0
exec GOEDIT.ELF
EOF

vgate_file script3-15.txt <<'EOF'
wm
dui
echo rx-gotabwm-palette-ok
EOF

vgate_run 15 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-15' \
    --script '$RUN_DIR/script-15.txt' \
    --script2 '$RUN_DIR/script2-15.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-p,e,d,i,t,return,ctrl-shift-p,s,e,t,t,return' \
    --input-chords-after 'goedit: declare accepted' \
    --script3 '$RUN_DIR/script3-15.txt' \
    --script3-after 'goset: declare accepted' \
    --script-expect 'rx-gotabwm-palette-ok' --timeout 300

vgate_assert 15 serial-contains 'settings: idle_minutes=120 (persisted)'
vgate_assert 15 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 15 serial-contains 'gotabwm: mode live'
vgate_assert 15 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 15 serial-contains 'goedit: declare accepted'
vgate_assert 15 serial-contains 'gotabwm: rail n=1'
# Leg 1: 'edit' ranks the open Edit tab first and focuses it — the focus
# marker only prints on a successful tab pick.
vgate_assert 15 serial-contains 'gotabwm: palette open n='
vgate_assert 15 serial-contains 'gotabwm: palette filter q=edit n='
vgate_assert 15 serial-contains 'gotabwm: palette focus id='
vgate_assert 15 serial-contains 'gotabwm: palette dismiss'
# Leg 2: 'sett' ranks a Settings row first and execs GOSET, which then
# declares for real over WM_RPC — the launch is hosted, not just exec'd.
# A seat-spawned exec does not print 'exec: loaded' (that is the monitor
# command's line); its kernel-side record is the measured-boot receipt.
vgate_assert 15 serial-contains 'gotabwm: palette filter q=sett n='
vgate_assert 15 serial-contains 'gotabwm: palette exec GOSET.ELF'
vgate_assert 15 serial-contains 'verdict=measured name=GOSET.ELF'
vgate_assert 15 serial-contains 'goset: declare accepted'
vgate_assert 15 serial-contains 'gotabwm: rail n=2'
vgate_assert 15 serial-contains 'rx-gotabwm-palette-ok'
vgate_assert 15 serial-absent '[EXC] parking:'
vgate_assert 15 serial-absent 'exited status=139'

# --- M123c (#2577) run 16: progress rows + cancel, end to end -----------
#
# GOPROGRESS.ELF is the driver (user/go/goprogress): it owns a window,
# binds it, posts one kind-22 report ("Copying", op=1, 40%), then polls
# for the seat's kind-23 cancel once a tick. HOST PREREQUISITE:
#   bash tools/go/build-web.sh goprogress GOPROGRESS -> .build/go/GOPROGRESS.ELF
#
# The chain and each marker that proves its link:
#
#   goprogress: bound id=<n>           the app's window bound to the Go
#                                      seat (the kind-22 request rides the
#                                      authenticated exchange)
#   goprogress: progress sent op=1     the app's OWN ack — the seat
#                                      applied the report
#   gotabwm: notify progress id=<n>    the row exists (printed on create,
#                                      never per update)
#   gotabwm: notify center open        the scripted clock click opened it
#   gotabwm: notify progress cancel    the row's Cancel zone was acted on;
#                                      id=<n> op=1 sent=1
#   goprogress: progress cancel op=1   the kind-23 push reached the app's
#                                      mailbox — user intent delivered
#
# The pointer batch is anchored on the seat's create marker, like run 06
# anchors on the paint: the row exists the instant `notify progress id=`
# prints. (1198,702) is the clock panel — it opens the center; (876,227)
# lands inside row 0's trailing-48px Cancel zone (the panel is x=380..900,
# y=180; row 0 spans y=210..244; the zone is x>=852).
#
# exec-order: assert-proven -- the run ends on `rx-gotabwm-progress-ok`,
# which only script3 prints, and script3 is held behind
# `goprogress: progress cancel`, a marker only the app can print after
# the kind-23 push lands.
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOPROGRESS.ELF")
if not os.path.exists(src):
    sys.exit("GOPROGRESS.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-web.sh goprogress GOPROGRESS")
shutil.copy(src, os.path.join(share, "GOPROGRESS.ELF"))
print("staged GOPROGRESS.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOPROGRESS.ELF")))
PY

# The rms are load-bearing: earlier legs leave SESSION.TABS rows (their
# reexec'd tabs race the declare the pointer batch anchors on) and a
# NOTIFY.HIST (restored toasts fill the center's early rows, so the
# scripted (876,227) click lands on a stale row's zone instead of the
# progress row's Cancel — observed run 16 dismissing id=0 2026-10-20).
vgate_file script-16.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm NOTIFY.HIST
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-16.txt <<'EOF'
dui focus 0
exec GOPROGRESS.ELF
EOF

vgate_file script3-16.txt <<'EOF'
wm
dui
echo rx-gotabwm-progress-ok
EOF

vgate_run 16 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-16' \
    --script '$RUN_DIR/script-16.txt' \
    --script2 '$RUN_DIR/script2-16.txt' \
    --script2-after 'gotabwm: win focus' \
    --pointer-virtio '1198,702,d;1198,702,u;876,227,d;876,227,u' \
    --pointer-virtio-after 'gotabwm: notify progress id=' \
    --script3 '$RUN_DIR/script3-16.txt' \
    --script3-after 'goprogress: progress cancel' \
    --script-expect 'rx-gotabwm-progress-ok' --timeout 300

vgate_assert 16 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 16 serial-contains 'gotabwm: mode live'
vgate_assert 16 serial-absent 'gotabwm: mode demo'
vgate_assert 16 serial-contains 'exec: loaded GOPROGRESS.ELF'
vgate_assert 16 serial-contains 'goprogress: bound id='
vgate_assert 16 serial-contains 'goprogress: progress sent op=1'
vgate_assert 16 serial-absent 'goprogress: FAIL'
vgate_assert 16 serial-contains 'gotabwm: notify progress id='
vgate_assert 16 serial-contains 'gotabwm: notify center open'
vgate_assert 16 serial-contains 'gotabwm: notify progress cancel id='
vgate_assert 16 serial-contains ' op=1 sent=1'
vgate_assert 16 serial-contains 'goprogress: progress cancel op=1'
vgate_assert 16 serial-contains 'rx-gotabwm-progress-ok'
vgate_assert 16 serial-absent '[EXC] parking:'
vgate_assert 16 serial-absent 'exited status=139'

# The causal order, like run 06's: the seat's create line precedes the
# app's accepted ack (the ack is the ANSWER), and the seat's cancel line
# precedes the app's observed cancel (the app can only print after the
# kind-23 push lands). One sender id and one op throughout.
vgate_assert 16 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def at(pat, what):
    m = re.search(pat, ser)
    if not m:
        sys.exit("no %s in the serial log" % what)
    return m

created = at(r"(?m)^gotabwm: notify progress id=(\d+) op=1 ", "the row's create line")
sent = at(r"(?m)^goprogress: progress sent op=1$", "the app's accepted ack")
cancelled = at(r"(?m)^gotabwm: notify progress cancel id=(\d+) op=1 sent=1$", "the seat's cancel push")
seen = at(r"(?m)^goprogress: progress cancel op=1$", "the app's observed cancel")
if not (created.start() < sent.start() and cancelled.start() < seen.start()):
    sys.exit("progress chain out of order: create=%d sent=%d cancel=%d seen=%d"
             % (created.start(), sent.start(), cancelled.start(), seen.start()))
if created.group(1) != cancelled.group(1):
    sys.exit("cancel named id=%s, want the reporter id=%s"
             % (cancelled.group(1), created.group(1)))
PY

# --- M123a (#2575) runs 17-18: kernel refusals become actionable toasts ---
#
# The seat's refusal sites post a notify toast with a per-errno action
# (user/go/gotabwm/refusal.go); serial markers stay exactly as they were.
#
# Run 17 — missing binary -> toast -> Retry: APPS.TXT carries one Ghost
# row for MISSING.ELF, which IS staged so the launcher's availability
# probe admits it. script2 then `vf rm`s the binary behind the
# 'launcher open' marker and the pointer batch (anchored on the first
# presented launcher frame, one tick later — the rm lands well inside
# that window) clicks the row: exec -> ENOENT -> refusal toast -> a
# second click runs Retry, which execs again and reports ENOENT.
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOCALC.ELF")
if not os.path.isfile(src):
    sys.exit("GOCALC.ELF missing - build it first: bash tools/go/build-gocalc.sh")
shutil.copy(src, os.path.join(share, "MISSING.ELF"))
# One-row manifest so the Ghost row is unambiguously the click target.
open(os.path.join(share, "APPS.TXT"), "w").write(
    "# v2 test manifest for the M123a missing-binary leg\n"
    "MISSING.ELF | Ghost | g | dock=true\n")
print("staged MISSING.ELF + one-row APPS.TXT")
PY

vgate_file script-17.txt <<'EOF'
vf rm GOTABWM.DEMO
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF

vgate_file script2-17.txt <<'EOF'
vf rm MISSING.ELF
echo rx-m123a-rm
EOF

vgate_run 17 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-17' \
    --script '$RUN_DIR/script-17.txt' \
    --input-chords 'ctrl-space' --input-chords-after 'gotabwm: mode live' \
    --script2 '$RUN_DIR/script2-17.txt' --script2-after 'gotabwm: launcher open n=' \
    --pointer-virtio '130,150,c;112,702,c' \
    --pointer-virtio-after 'gotabwm: launcher presented' \
    --script-expect 'gotabwm: refusal act retry MISSING.ELF ENOENT' --timeout 300

vgate_assert 17 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 17 serial-contains 'gotabwm: mode live'
vgate_assert 17 serial-contains 'gotabwm: launcher open n=1'
vgate_assert 17 serial-contains 'rx-m123a-rm'
# The serial marker keeps its job; the toast rides beside it.
vgate_assert 17 serial-contains 'gotabwm: launcher missing MISSING.ELF'
vgate_assert 17 serial-contains 'gotabwm: refusal ENOENT exec MISSING.ELF act=retry'
vgate_assert 17 serial-contains 'gotabwm: notify paint'
vgate_assert 17 serial-contains 'gotabwm: notify dismiss'
# The click ran Retry: the re-exec refused ENOENT again, honestly named.
vgate_assert 17 serial-contains 'gotabwm: refusal act retry MISSING.ELF ENOENT'
vgate_assert 17 serial-absent '[EXC] parking:'
vgate_assert 17 serial-absent 'exited status=139'

# Run 18 — clipboard denied -> toast -> Open Settings (GOSET grants):
# the seat's clipboard lane is armed, then `lane-clipboard` over the
# HostCommand bus republishes ARMED with the clip bit cleared. A guest
# clipboard write (`clip m123a-denied`) then makes the seat emit CLIP_OUT
# into the revoked lane — the engine's emit path refuses it
# `lane_disabled`, the denial the seat converts into the EACCES-class
# toast whose click execs GOSET.ELF (the ADR 0054 grants surface). The
# refusal MUST come from the seat's own emit: `--host-clip-in` after the
# suspend is refused runner-side (M114c's "nothing stages while the lane
# is off") and never reaches the guest. HOST PREREQUISITE: GOSET.ELF
# staged beside the seat.
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOSET.ELF")
if not os.path.isfile(src):
    sys.exit("GOSET.ELF missing - build it first: bash tools/go/build-goset.sh")
shutil.copy(src, os.path.join(share, "GOSET.ELF"))
# The lane credential (ADR 0024 D8 binding: uid_system OWNERS row +
# image-bound SECRETS row). Value bytes ARE the HMAC key verbatim.
KEY = "m123akey" * 8  # 64 bytes, ASCII
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nGOTABWM.ELF\t644\t0\t-\n")
print("staged GOSET.ELF + host-int credential")
PY

vgate_file script-18.txt <<'EOF'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file script2-18.txt <<'EOF'
clip m123a-denied
EOF
vgate_run 18 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-18' \
    --script '$RUN_DIR/script-18.txt' \
    --host-clipboard \
    --host-cmd-after 'gotabwm: hostint armed:lane-clipboard' \
    --script2 '$RUN_DIR/script2-18.txt' --script2-after 'lanes=-' \
    --pointer-virtio '112,702,c' \
    --pointer-virtio-after 'gotabwm: refusal EACCES lane-clip' \
    --script-expect 'goset: declare accepted' --timeout 300

vgate_assert 18 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 18 serial-contains 'gotabwm: mode live'
vgate_assert 18 serial-contains 'gotabwm: hostint armed'
# The suspension re-armed an empty mask; the signed CLIP_IN was refused.
vgate_assert 18 serial-contains 'lanes=-'
vgate_assert 18 serial-contains 'gotabwm: hostint refuse lane=clip reason=lane_disabled'
vgate_assert 18 serial-contains 'gotabwm: refusal EACCES lane-clip act=grant'
vgate_assert 18 serial-contains 'gotabwm: notify paint'
vgate_assert 18 serial-contains 'gotabwm: notify dismiss'
# The click ran the grant action: GOSET.ELF exec'd and declared.
vgate_assert 18 serial-contains 'gotabwm: refusal act grant GOSET.ELF ok'
vgate_assert 18 serial-contains 'verdict=measured name=GOSET.ELF'
vgate_assert 18 serial-contains 'goset: declare accepted'
vgate_assert 18 serial-absent '[EXC] parking:'
vgate_assert 18 serial-absent 'exited status=139'

# --- M123b (#2576) run 19: the launcher's zero-match empty state -----------
# ctrl+space opens the strip, `zzz` drives the ranked list to zero matches
# (no manifest row ranks it), and the results region paints the shared
# widgets.EmptyState plate — Border ring, centred icon/headline/hint rows —
# while the seat emits `gotabwm: launcher empty` once for the frame that
# drew it. The snapshot reads the plate out of the guest's own scanout.
vgate_file script-19.txt <<'EOS'
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOS

# The run must end on the FULL filter, not on `launcher empty`: `zzz` is
# n=0 from the first stroke, so the empty plate paints — and the expect
# used to match — while strokes 2/3 were still in the host's 0.25 s
# pacing (observed 2026-10-20: serial stopped at `q=z`, the run torn
# down on the first `launcher empty`). The screenshot still gates on the
# empty marker; the plate is identical at any n=0 filter.
vgate_run 19 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-19' \
    --script '$RUN_DIR/script-19.txt' \
    --input-chords 'ctrl-space' --input-chords-after 'gotabwm: mode live' \
    --input-string 'zzz' --input-string-after 'gotabwm: launcher open n=' \
    --screenshot-after 'gotabwm: launcher empty' \
    --script-expect 'gotabwm: launcher filter q=zzz n=0' --timeout 300

vgate_assert 19 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 19 serial-contains 'gotabwm: mode live'
vgate_assert 19 serial-contains 'gotabwm: launcher open n='
vgate_assert 19 serial-contains 'gotabwm: launcher filter q=zzz n=0'
vgate_assert 19 serial-contains 'gotabwm: launcher empty'
vgate_assert 19 serial-absent 'gotabwm: launcher exec'
vgate_assert 19 serial-absent '[EXC] parking:'
vgate_assert 19 serial-absent 'exited status=139'

# The plate: results region x=8..254, y=140..712 (the strip minus header and
# accent rule), a 1px Border ring (51,65,85) around it, and centred text
# inside — counted as pixels that are neither Surface nor Border, so the
# assert holds whether the ui face resolved or the bitmap degrade painted.
# The --screenshot-after capture is a host-side PNG like run 03's — decode
# and scale the probe the same way (a raw-BGRX read failed this assert on
# 2026-10-20: 138305 PNG bytes < 3686400 wanted).
vgate_assert 19 snapshot 'screen-19-after' <<'PY'
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

BORDER = (0x33, 0x41, 0x55)
SURFACE = (0x22, 0x2d, 0x35)
# The PNG's colour-space shift needs a tolerance, like run 03's probe.
def near(c, t, tol=10):
    return all(abs(a - b) <= tol for a, b in zip(c, t))

scale = w / 1280.0
X0, X1 = int(8 * scale), int(254 * scale)
Y0, Y1 = int(140 * scale), int(711 * scale)
ring = textish = 0
for x in range(X0, X1):
    for y in (Y0, Y1):
        if near(px(x, y), BORDER):
            ring += 1
for y in range(Y0 + 1, Y1):
    for x in (X0, X1):
        if near(px(x, y), BORDER):
            ring += 1
for y in range(int(160 * scale), int(700 * scale)):
    for x in range(int(20 * scale), int(240 * scale)):
        c = px(x, y)
        if not near(c, SURFACE) and not near(c, BORDER):
            textish += 1
print("launcher empty leg: border-ring=%d interior-non-plate=%d" % (ring, textish))
assert ring >= 200, "empty-state border ring absent from the results region"
assert textish >= 200, "no empty-state text inside the plate"
PY

# --- M121d (#2567) run 20: the chrome focus indicator ------------------------
#
# The badge panel rides the bottom chrome band flush-left of the clock: the
# focused tab's title plus a chord-scope chip — "app" (the app's own
# KEY_DOWN scope), "term" (a tty-bound front-end the kernel's terminal
# chrome chords answer on), or "seat" (a seat modal holding the input sink,
# or no focused tab). One `gotabwm: focus` line prints per badge-state
# transition at the moment the seat's focus state moves — the `tab focus
# id=` discipline — so a rapid cycle names every switch even when several
# land inside one composite tick; the painted truth is the snapshot
# assert's job.
#
# LIVE seat (vf rm GOTABWM.DEMO — the run 15/16 pattern) so no bounded
# choreography races the legs. Four tabs exec in script2 and declare in
# rail order — the execs RACE: heavier binaries boot slower, so the rail
# is not guaranteed script order (observed 2026-10-20: opens id 5,6,3,4
# -> strip [Term,Web,Edit,Files]). Each new declare still takes focus,
# so the badge's last declare line names whichever app landed last. The
# chord batch then rides the same 0.25 s/stroke pacing:
#
#   alt-tab x4   focus wraps the four tabs one focus line per switch
#   ctrl-shift-w the M121b close: WEB leaves the strip and focus falls
#                to the tab that shifts into its slot — the NEXT walk
#                entry when a rail cell shifts in, or the new last tab
#                when WEB closed rightmost — the card's tab-close leg
#
# The close is also this run's ORDERING anchor: `gotabwm: tab close id=`
# can only print after every alt-tab in the batch was processed, so
# script3's anchor can never outrun the cycle.
#
# The `vf rm GOTABWM.IDLE.TEST` + `settings set idle_minutes 120` pair is
# load-bearing exactly as in run 15: run 07 persists idle_minutes=1 and
# seeds the 2-ticks/min fixture on this same share, which would leave
# dim=2/lock=4 in force — every later stroke eaten as an idle WAKE rather
# than reaching the seat's chords.
#
# The four tabs script2 execs are all real binaries: GOEDIT/GOFILES are
# staged above; GOTERM and WEB ride this leg's own stage — without it the
# execs fail ENOENT, the rail stops at n=2, and every downstream anchor
# starves (observed 2026-10-20). HOST PREREQUISITES:
#   bash tools/go/build-goterm.sh            -> .build/go/GOTERM.ELF
#   bash tools/go/build-web.sh               -> .build/go/WEB.ELF
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, builder in (("GOTERM.ELF", "tools/go/build-goterm.sh"),
                      ("WEB.ELF", "tools/go/build-web.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash %s"
                 % (name, src, builder))
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)"
          % (name, os.path.getsize(os.path.join(share, name))))
PY
vgate_file script-20.txt <<'EOS'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm GOTABWM.IDLE.TEST
settings set idle_minutes 120
wm
exec GOTABWM.ELF
EOS

vgate_file script2-20.txt <<'EOS'
dui focus 0
exec GOEDIT.ELF
exec GOFILES.ELF
exec GOTERM.ELF
exec WEB.ELF
EOS

vgate_file script3-20.txt <<'EOS'
wm
dui
echo rx-gotabwm-focus-ok
EOS

vgate_run 20 -- \
    --via-virtio \
    --screen '$RUN_DIR/screen-20' \
    --script '$RUN_DIR/script-20.txt' \
    --script2 '$RUN_DIR/script2-20.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'alt-tab,alt-tab,alt-tab,alt-tab,ctrl-shift-w' \
    --input-chords-after 'gotabwm: rail n=4' \
    --screenshot-after 'gotabwm: focus scope=term title=Term' \
    --script3 '$RUN_DIR/script3-20.txt' \
    --script3-after 'gotabwm: tab close id=' \
    --script-expect 'rx-gotabwm-focus-ok' --timeout 300

vgate_assert 20 serial-contains 'settings: idle_minutes=120 (persisted)'
vgate_assert 20 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 20 serial-contains 'gotabwm: mode live'
vgate_assert 20 serial-contains 'exec: loaded GOEDIT.ELF'
vgate_assert 20 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 20 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 20 serial-contains 'exec: loaded WEB.ELF'
vgate_assert 20 serial-contains 'goedit: declare accepted'
vgate_assert 20 serial-contains 'gofiles: declare accepted'
vgate_assert 20 serial-contains 'goterm: declare accepted'
vgate_assert 20 serial-contains 'gotabwm: rail n=4'
# The declares themselves walked the badge — seat at boot, then each new
# declare's title+scope — and the alt-tab cycle then printed the same
# four in rail order again. scope=seat's boot line opens the count.
vgate_assert 20 serial-contains 'gotabwm: focus scope=seat'
vgate_assert 20 serial-contains 'gotabwm: focus scope=app title=Edit'
vgate_assert 20 serial-contains 'gotabwm: focus scope=term title=Files'
vgate_assert 20 serial-contains 'gotabwm: focus scope=term title=Term'
vgate_assert 20 serial-contains 'gotabwm: focus scope=app title=Web'
vgate_assert 20 serial-contains 'gotabwm: tab close id='
vgate_assert 20 serial-contains 'rx-gotabwm-focus-ok'
vgate_assert 20 serial-absent '[EXC] parking:'
vgate_assert 20 serial-absent 'exited status=139'

# The cycle, in order: the four titled focus lines after `rail n=4` are
# the alt-tab switches — one line per switch at decision time, so the
# batch draining inside one tick still names all four — and the titled
# line after `tab close id=` is the close's focus landing. Declares are
# NOT required to each print (one RPC drain can serve several declares;
# the badge's transition reporter then names the batch's last state —
# the cycle is the leg's per-switch proof).
vgate_assert 20 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
want = [("app", "Edit"), ("term", "Files"), ("term", "Term"), ("app", "Web")]
lines = [(m.start(), m.group(1), (m.group(2) or "").strip())
         for m in re.finditer(
             r"(?m)^gotabwm: focus scope=(\w+)(?: title=(.*))?$", ser)]
rail = ser.index("gotabwm: rail n=4")
close = ser.index("gotabwm: tab close id=")
# rail n=4 and the last declare's focus line land in the same tick (the
# rail marker prints during paint, the badge's line after) — the cycle is
# the LAST four titled lines before the close, not the first four after.
# GOTERM retitles to `Term — <cwd>` on its first paint, and the retitle
# races the alt-tab cycle (observed 2026-10-20: the cycle's Term line
# already carried `Term — /`), so Term entries compare by prefix like
# the post-close line below.
titled = [(s, "Term" if s == "term" and t.startswith("Term") else t)
          for pos, s, t in lines if rail < pos < close and t]
cycle = titled[-4:]
# The rail order is the exec race's, not script order (observed
# 2026-10-20: opens id 5,6,3,4 -> strip [Term,Web,Edit,Files]), so the
# assert pins the leg's contract, not a permutation: the batch walked
# each of the four tabs exactly once — every switch printed its own
# line, which is the badge discipline this card proves.
if sorted(cycle) != sorted(want):
    sys.exit("alt-tab cycle %r is not one pass over %r"
             % (cycle, want))
# GOTERM retitles to `Term — <cwd>` on its first paint — compare Term by
# prefix here too, same as the cycle entries above.
post = [(s, "Term" if s == "term" and t.startswith("Term") else t)
        for pos, s, t in lines if pos > close and t]
# The close hands focus to a ring NEIGHBOUR of the closed tab: the cell
# shifting into its slot (the walk entry after Web, wrapped) when a cell
# shifts in, else the new last tab (the entry before Web) when Web was
# rightmost (tabs.go CloseTab). Web's rail slot is the race's, so either
# ring neighbour is the documented close-fall: cycle[-2] or cycle[0].
neighbours = {cycle[-2], cycle[0]}
if not post or post[0] not in neighbours:
    sys.exit("close landed the badge on %r, want a rail neighbour of "
             "the closed tab %r" % (post[:1], sorted(neighbours)))
print("M121d focus badge: cycle %r, close -> %r" % (cycle, post[0]))
PY

# THE pixel assert: the badge's own rect on the captured frame — the
# --screenshot-after PNG is the run 03 decode (colour-space tolerant):
# the ChromeBg panel, accent (the scope chip + the seat rule) and ink text
# inside focusRect = (clock x) - 4 - 216 .. (clock x) - 4.
vgate_assert 20 snapshot 'screen-20-after' <<'PY'
import sys, zlib, struct
from collections import Counter
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
x0, y0, pw, ph = 1124 - 4 - 216, 720 - 8 - 20, 216, 20
chrome_bg = (0x11, 0x17, 0x1c)
modal = Counter(); accent = ink = total = 0
for y in range(int(y0 * scale), int((y0 + ph) * scale)):
    for x in range(int(x0 * scale), int((x0 + pw) * scale)):
        r, g, b = px(x, y)
        total += 1
        modal[(r, g, b)] += 1
        if min(r, g, b) >= 150:
            ink += 1
        if abs(r - 0x3b) <= 32 and abs(g - 0x82) <= 32 and abs(b - 0xf6) <= 32:
            accent += 1
best, best_n = modal.most_common(1)[0]
dist = max(abs(best[0]-chrome_bg[0]), abs(best[1]-chrome_bg[1]),
           abs(best[2]-chrome_bg[2]))
print("badge rect %dx%d (%d px): modal=#%02x%02x%02x n=%d accent=%d ink=%d"
      % (int(pw*scale), int(ph*scale), total,
         best[0], best[1], best[2], best_n, accent, ink))
assert dist <= 4, ("the badge rect is not the seat's ChromeBg (modal "
                   "#%02x%02x%02x) — the panel was not painted"
                   % (best[0], best[1], best[2]))
assert best_n >= 4000, "the badge panel does not cover its rect"
assert accent > int(ph * scale), "no scope chip / seat rule on the badge"
assert ink >= 20, "no title text on the badge"
PY
