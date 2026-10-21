# go-paint.spec -- M141a (issue #2787): GOPAINT.ELF on the draw-v2 canvas.
#
# Three legs, two boot shapes — driven by the kernel's own input rules:
#
#   01  SHIM (no seat): the kernel hit-tests every pointer sample and pushes
#       MOUSE_* to the window in LOCAL coords (the go-calc pad-leg shape — a
#       seat's content forward is terminal-only, so canvas apps under GOTABWM
#       never see the pointer). A scripted gesture set exercises all five
#       tools; ctrl-z twice reverts the newest two ops; ctrl-s raises the
#       save picker, a typed name lands /host/PAINT1.QOI, and a second exec
#       reopens it — every hop pinned by the app's own sum= digests, the
#       pixel probe, and the file's host-verified SHA-256.
#   02  SEAT (GOTABWM): the M124a drag — GOFILES arms PIC.QOI, the release
#       lands on GOPAINT's split pane, the in-app confirm answers the
#       staged payload, and the canvas becomes the image. GOPAINT has no
#       APPS.TXT row in the repo manifest (M132b reserved grants only), so
#       this leg stages one on the gate's own share — the same seam
#       go-fileman run 13 uses for its MISSING.ELF refusal row.
#   03  SEAT: M125a state — tool rect, ctrl-shift-w closes (the seat
#       collects the blob), ctrl-shift-t reopens the recorded bin, and the
#       restored app reloads the file and the tool selection.
#
# M141b (#2788) adds two store legs on a second share (paint-store-share),
# shim-mode like run 01, driven by STORE.ELF .SH journeys inside gosh:
#
#   04  A stock APPS.TXT (no GOPAINT row anywhere — the release's signed
#       ReleaseManifestRow self-registers at install), a host flintd
#       serving the `gopaint` stream on this gate's own lane (4859), then:
#       ls folds the signed catalog card, a tampered-ELF install refuses
#       by name (elf_mismatch GOPAINT.ELF), the real install verifies and
#       publishes, and scripted pointer work draws + ctrl-s saves
#       PSTORE.QOI.
#   05  The round trip — store remove, reinstall, reopen the saved file,
#       a fill edits it, ctrl-s saves the same name. The leftover install
#       is deleted at the START of run 04's .SH (iteration 1's remove
#       honestly refuses not_installed), so every repeat installs for
#       real. Both legs end on the app's own `gopaint: quit` marker —
#       never a script echo: a `gosh: GOPAINT.ELF: wait failed` spawn
#       race (observed under host load) lets the .SH run ahead while the
#       app is still drawing, and a script-supplied expect would stop the
#       VM mid-chords.
#
# vgate_repeat 3 (BOOTS overridable) is the card's K=3: every iteration
# runs install -> launch -> draw -> save -> remove -> reinstall -> open ->
# edit -> save, with the tamper refusal inside each iteration's run 04.
#
# Geometry (run 01): the window opens at (24,24), 832x600. The document's
# window-local origin is (64,32); everything interactive sits at local
# y >= 28, clear of the kernel's 16px title band (a press inside it drags
# the WINDOW, it does not deliver). Pointer digits below are SCANOUT coords
# (local + 24,24). Palette cell i sits at (8 + (i%4)*13, 200 + (i/4)*13) with
# an 11px tile.
#
#   palette 9   (orange)    local (26,231)   -> scanout (50,255)
#   brush L                  doc (40,40)->(120,40)->(120,100)
#                            -> scanout (128,96)->(208,96)->(208,156)
#   line button              local (28,65)   -> scanout (52,89)
#   line drag                doc (240,40)->(300,140)
#                            -> scanout (328,96)->(388,196)
#   rect button              local (28,91)   -> scanout (52,115)
#   rect drag                doc (100,80)->(220,180)
#                            -> scanout (188,136)->(308,236)
#   palette 11  (green)      local (52,231)  -> scanout (76,255)
#   fill button              local (28,117)  -> scanout (52,141)
#   fill click (rect inside) doc (160,120)   -> scanout (248,176)
#   erase button             local (28,143)  -> scanout (52,167)
#   erase drag               doc (220,90)->(320,90)  (cuts the line)
#                            -> scanout (308,146)->(408,146)
#
# Every sum=/probe value below is pinned in class-A too: gatevec_test.go's
# gateGesture replays this exact sequence and asserts the same digests, so
# the spec's literals cannot drift from the implementation.
#
# HOST PREREQUISITE (the setup hook fails honestly when missing):
#   bash tools/go/build-gopaint.sh   ->  .build/go/GOPAINT.ELF
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF  (runs 02-03)
#   bash tools/go/build-files.sh     ->  .build/go/GOFILES.ELF  (run 02)
#   bash tools/go/build-gosh.sh      ->  .build/go/GOSH.ELF     (runs 04-05)
#   bash tools/go/build-store.sh     ->  .build/go/STORE.ELF    (runs 04-05)
#   bash tools/go/build-flint.sh     ->  .build/go/FLINT.ELF    (runs 04-05)
#   ../flint-server checkout (or FLINT_SERVER_DIR=...) — the hook zig-builds
#   flintd and serves the signed gopaint stream on 127.0.0.1:4859.

vgate_name go-paint "M141a #2787 + M141b #2788: GOPAINT.ELF — tools/undo/QOI, drop-in, save_state, signed STORE install + round-trip K=3"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

# --- run 01: shim-mode draw / undo / save / reopen --------------------------

vgate_file script-01.txt <<'EOF'
exec GOPAINT.ELF
EOF

vgate_file script2-01.txt <<'EOF'
exec GOPAINT.ELF /host/PAINT1.QOI
EOF

vgate_file script3-01.txt <<'EOF'
echo rx-go-paint-ok
EOF

# --- run 02: the seat-mediated drop -----------------------------------------

vgate_file script-02.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
dui focus 0
exec GOFILES.ELF /host/DROP
EOF

vgate_file script3-02.txt <<'EOF'
exec GOPAINT.ELF
EOF

# --- run 03: close -> reopen -> restored state -------------------------------

vgate_file script-03.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-03.txt <<'EOF'
dui focus 0
exec GOPAINT.ELF /host/DROP/SEED.QOI
EOF

vgate_file script3-03.txt <<'EOF'
echo rx-go-paint-state-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for elf, build in (("GOPAINT.ELF", "tools/go/build-gopaint.sh"),
                   ("GOTABWM.ELF", "tools/go/build-gotabwm.sh"),
                   ("GOFILES.ELF", "tools/go/build-files.sh")):
    src = os.path.join(".build", "go", elf)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash %s"
                 % (elf, src, build))
    shutil.copy(src, os.path.join(share, elf))
# The drop + restore fixture: the repo's own 160x120 QOI decoder fixture —
# well under the 64 KiB drag-envelope bound — staged once, named twice so
# run 03's restore leg can own its path.
drop = os.path.join(share, "DROP")
os.makedirs(drop, exist_ok=True)
qoi = os.path.join("tests", "fixtures", "qoi", "viewer_160x120.qoi")
if not os.path.exists(qoi):
    sys.exit("QOI fixture missing (expected " + qoi + ")")
shutil.copy(qoi, os.path.join(drop, "PIC.QOI"))
shutil.copy(qoi, os.path.join(drop, "SEED.QOI"))
# GOPAINT has no manifest row in the repo's image/apps.txt (M132b reserved
# the grant line only); the seat's drag admission reads opens= from the
# SHARE's APPS.TXT, so append the row here — the go-fileman run-13
# MISSING.ELF precedent, one gate-local line, never upstreamed.
apps = os.path.join(share, "APPS.TXT")
with open(apps) as f:
    body = f.read()
if "GOPAINT.ELF" not in body:
    if not body.endswith("\n"):
        body += "\n"
    body += "GOPAINT.ELF | Paint | P | dock=false | v=2 | opens=image\n"
    with open(apps, "w") as f:
        f.write(body)
# Runs 02/03 exec the seat explicitly; keep the autostart off (wm=none) so
# the boot proves the exec'd seat, and run 01 stays the bare shim.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
print("staged GOPAINT/GOTABWM/GOFILES + DROP/{PIC,SEED}.QOI + APPS.TXT row")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/paint-screen' \
    --input --via-virtio \
    --script '$RUN_DIR/script-01.txt' \
    --pointer-virtio '50,255,d;50,255,u;128,96,d;208,96;208,156;208,156,u;52,89,d;52,89,u;328,96,d;388,196;388,196,u;52,115,d;52,115,u;188,136,d;308,236;308,236,u;76,255,d;76,255,u;52,141,d;52,141,u;248,176,d;248,176,u;52,167,d;52,167,u;308,146,d;408,146;408,146,u' \
    --pointer-virtio-after 'gopaint: ready' \
    --input-chords 'ctrl-z,ctrl-z,ctrl-s' \
    --input-chords-after 'gopaint: commit erase' \
    --input-string $'PAINT1.QOI\n' \
    --input-string-after 'gopaint: pick save' \
    --script2 '$RUN_DIR/script2-01.txt' \
    --script2-after 'gopaint: saved ' \
    --script3 '$RUN_DIR/script3-01.txt' \
    --script3-after 'gopaint: loaded ' \
    --script-expect 'rx-go-paint-ok' --timeout 420

vgate_assert 01 serial-contains 'exec: loaded GOPAINT.ELF'
vgate_assert 01 serial-contains 'gopaint: open id='
vgate_assert 01 serial-contains 'gopaint: not-tab-aware'
vgate_assert 01 serial-contains 'gopaint: canvas 640x480'
vgate_assert 01 serial-contains 'gopaint: ready'

# The gesture set — every commit carries its touched count and canvas digest.
vgate_assert 01 serial-contains 'gopaint: color 9'
vgate_assert 01 serial-contains 'gopaint: commit brush n=710 sum=5c81f313b5e994e1'
vgate_assert 01 serial-contains 'gopaint: tool line'
vgate_assert 01 serial-contains 'gopaint: commit line n=513 sum=7b8f7c510a15d763'
vgate_assert 01 serial-contains 'gopaint: commit rect n=440 sum=84b28dfa95fb6f29'
vgate_assert 01 serial-contains 'gopaint: color 11'
vgate_assert 01 serial-contains 'gopaint: commit fill n=11677 sum=5b5a7eeede3e7cdb'
vgate_assert 01 serial-contains 'gopaint: commit erase n=513 sum=1736b82007e7fe87'

# Undo twice: the erase reverts (line restored), then the fill — the probe
# pixel returns to paper and the digest to the post-rect value.
vgate_assert 01 serial-contains 'gopaint: undo depth=4 sum=5b5a7eeede3e7cdb probe=0xff00e436'
vgate_assert 01 serial-contains 'gopaint: undo depth=3 sum=84b28dfa95fb6f29 probe=0xfffff1e8'

# Save through the picker, then a second exec reopens the file: the reopened
# canvas digest equals the post-undo one — "reopen gets the same pixels back".
vgate_assert 01 serial-contains 'gopaint: pick save /host/PAINT1.QOI'
vgate_assert 01 serial-contains 'gopaint: saved /host/PAINT1.QOI n=6042 sum=84b28dfa95fb6f29'
vgate_assert 01 serial-contains 'gopaint: loaded /host/PAINT1.QOI 640x480 sum=84b28dfa95fb6f29'
vgate_assert 01 serial-contains 'rx-go-paint-ok'

vgate_assert 01 serial-absent 'gopaint: open refused'
vgate_assert 01 serial-absent 'gopaint: save refused'
vgate_assert 01 serial-absent 'gopaint: undo empty'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The file on the share: SHA-256 of the actual saved bytes plus a QOI decode
# probing two pixels — the filled rect interior is green (palette 11) and the
# probe point the undo restored is paper.
vgate_assert 01 python <<'PY'
import hashlib, os
share = os.environ["VG_SHARE"]
data = open(os.path.join(share, "PAINT1.QOI"), "rb").read()
sha = hashlib.sha256(data).hexdigest()
assert sha == "7a49b337e2f459a9aabe99ee927f353c3634afa42c8ce0ab136178e19b98c3bd", \
    "PAINT1.QOI sha256 %s" % sha
assert data[:4] == b"qoif", "not a QOI"
w = int.from_bytes(data[4:8], "big")
h = int.from_bytes(data[8:12], "big")
assert (w, h) == (640, 480), "dims %dx%d" % (w, h)
print("PAINT1.QOI: %d bytes sha256=%s %dx%d" % (len(data), sha[:12], w, h))
PY

# --- run 02: the seat drop ----------------------------------------------------
# go-drag run 02's shape with GOPAINT as the target: press PIC.QOI's row,
# a held move through the split, release mid-right-pane; the seat's opens=
# admission reads the staged APPS.TXT row, the target's confirm dialog
# answers, and the canvas becomes the image.
vgate_run 02 -- \
    --screen '$RUN_DIR/paint-drop-screen' \
    --via-virtio \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'ctrl-shift-v' \
    --input-chords-after 'gotabwm: rail n=2' \
    --pointer-virtio '40,62,d;200,200;320,240;480,280;900,360,u' \
    --pointer-virtio-after 'gotabwm: split v' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'gofiles: ready' \
    --input-string $'\t\n' \
    --input-string-after 'gopaint: drop-confirm' \
    --script-expect 'gopaint: drop image/qoi 160x120' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert 02 serial-contains 'gofiles: ready'
vgate_assert 02 serial-contains 'exec: loaded GOPAINT.ELF'
vgate_assert 02 serial-contains 'gopaint: ready'

vgate_assert 02 serial-contains 'gotabwm: split v'
vgate_assert 02 serial-contains 'gofiles: drag arm PIC.QOI image/qoi'
vgate_assert 02 serial-contains 'gotabwm: drag over id='
vgate_assert 02 serial-contains 'accept=1'
vgate_assert 02 serial-contains 'gotabwm: drag drop id='

# The confirm gated the replace: dialog raised, the typed Tab+Return chose
# Yes, and the canvas is the dropped raster.
vgate_assert 02 serial-contains 'gopaint: drop-confirm'
vgate_assert 02 serial-contains 'gopaint: drop image/qoi 160x120 sum=9ea88033bfdfe325'

vgate_assert 02 serial-absent 'gopaint: drop refused'
vgate_assert 02 serial-absent 'gopaint: drop cancel'
vgate_assert 02 serial-absent 'gotabwm: drag refuse'
vgate_assert 02 serial-absent 'gotabwm: drag cancel'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# --- run 03: save_state through close + reopen -------------------------------
# 'r' selects the rect tool (keys reach the focused app under the seat even
# though the pointer never does), ctrl-shift-w closes the tab — the seat
# collects the blob first — and ctrl-shift-t re-execs the recorded bin.
vgate_run 03 -- \
    --screen '$RUN_DIR/paint-state-screen' \
    --via-virtio \
    --script '$RUN_DIR/script-03.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'gotabwm: win focus' \
    --input-chords 'r,ctrl-shift-w,ctrl-shift-t' \
    --input-chords-after 'gopaint: ready' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'gopaint: state restored' \
    --script-expect 'rx-go-paint-state-ok' --timeout 300

vgate_assert 03 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 03 serial-contains 'exec: loaded GOPAINT.ELF'
vgate_assert 03 serial-contains 'gopaint: loaded /host/DROP/SEED.QOI 160x120'
vgate_assert 03 serial-contains 'gopaint: tool rect'
vgate_assert 03 serial-contains 'gotabwm: tab close id='
vgate_assert 03 serial-contains 'gotabwm: reopen GOPAINT.ELF'
vgate_assert 03 serial-contains 'gopaint: state restored file=/host/DROP/SEED.QOI tool=rect'
vgate_assert 03 serial-contains 'rx-go-paint-state-ok'
vgate_assert 03 serial-absent 'gopaint: state stale'
vgate_assert 03 serial-absent 'gopaint: open refused'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# --- runs 04/05: M141b — GOPAINT through the STORE bundle path -------------

vgate_file script-04.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script2-04.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/P4.SH"
EOF

vgate_file script-05.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script2-05.txt <<'EOF'
exec GOSH.ELF -c "source /host/FLINTJ/P5.SH"
EOF

vgate_setup_python <<'PY'
import hashlib, json, os, shutil, socket, subprocess, sys, time

run = os.environ["RUN_DIR"]
repo = os.getcwd()

for name, cmd in (
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
    ("STORE.ELF", "bash tools/go/build-store.sh"),
    ("FLINT.ELF", "bash tools/go/build-flint.sh"),
):
    if not os.path.isfile(os.path.join(".build", "go", name)):
        sys.exit(name + " missing (expected .build/go/" + name +
                 ") - build it first: " + cmd)

# No dsk-special manifest entry: GOPAINT self-registers at install from the
# signed ReleaseManifestRow, so the stock manifest must NOT name it.
apps_stock = open(os.path.join("image", "apps.txt"), encoding="utf-8").read()
if "GOPAINT.ELF" in apps_stock:
    sys.exit("image/apps.txt carries GOPAINT.ELF — store installs self-register")

# The env-gated generator (the go-gostore seam) signs the `gopaint` release
# under the repo's first-party fixture seed, pinning THIS build's ELF sha —
# the build is not bit-reproducible so the fixture regenerates per run.
# ReleaseCaps asks for exactly the fleet reservation's words: the `*` row's
# non-widening keep covers the ask, so the journey needs no consent leg.
fixture_dir = os.path.join(run, "fixtures")
os.makedirs(fixture_dir, exist_ok=True)
gopaint_elf = os.path.abspath(os.path.join(".build", "go", "GOPAINT.ELF"))
g = subprocess.run(
    ["go", "test", "./store", "-run", "TestGenReleaseFixture", "-count=1"],
    cwd="user/go",
    env={**os.environ,
         "STORE_GEN_FIXTURE": "1",
         "STORE_FIXTURE_ELF": gopaint_elf,
         "STORE_FIXTURE_NAME": "GOPAINT",
         "STORE_FIXTURE_VERSION": "1.0.0",
         "STORE_FIXTURE_ROW":
             "GOPAINT.ELF | Paint | P | dock=false | v=2 | opens=image",
         "STORE_FIXTURE_STREAM": "0199de2d-dc00-7000-8000-00000000b020",
         "STORE_FIXTURE_CHANGE": "0199de2d-dc00-7000-8000-00000000c020",
         "STORE_FIXTURE_TS": "1760000600000",
         "STORE_FIXTURE_MSG": "gopaint release",
         "STORE_FIXTURE_SUMMARY": "Paint on the draw-v2 canvas",
         "STORE_FIXTURE_DESCRIPTION":
             "GOPAINT draws on a 640x480 canvas.\nInstalled through STORE.",
         "STORE_FIXTURE_CATEGORY": "app",
         "STORE_FIXTURE_CAPS": "file,window,memory,process,debug",
         "STORE_FIXTURE_DIR": fixture_dir,
         "STORE_FIXTURE_TAG": "gopaint"},
    capture_output=True, text=True)
if g.returncode != 0:
    sys.exit("gopaint fixture generation failed:\n%s%s"
             % (g.stdout[-2000:], g.stderr[-2000:]))
gp_line = open(os.path.join(fixture_dir, "release-gopaint-stream.jsonl"),
               "r", encoding="utf-8").read().strip()
gp_change = json.loads(gp_line)
gp_go = open(os.path.join(fixture_dir, "release-gopaint.go"),
             "r", encoding="utf-8").read()
gp_sid = gp_change["stream"]
gp_elf = open(gopaint_elf, "rb").read()
gp_stream_rec = {"id": gp_sid, "name": "gopaint", "head": gp_change["id"],
                 "created": gp_change["ts"], "forked_from": None}

# flintd on this gate's own lane (4859) — the go-gostore sibling pattern.
flint_server_dir = os.path.abspath(
    os.environ.get("FLINT_SERVER_DIR") or os.path.join(repo, "..", "flint-server"))
if not os.path.isfile(os.path.join(flint_server_dir, "build.zig")):
    sys.exit("flint-server checkout missing at %s - clone drawmeanelephant/"
             "flint-server there or set FLINT_SERVER_DIR" % flint_server_dir)
flintd_rev = subprocess.run(
    ["git", "-C", flint_server_dir, "rev-parse", "HEAD"],
    capture_output=True, text=True).stdout.strip()
subprocess.check_call(["zig", "build"], cwd=flint_server_dir)
flintd = os.path.join(flint_server_dir, "zig-out", "bin", "flintd")
if not os.path.isfile(flintd):
    sys.exit("flintd missing after zig build (expected " + flintd + ")")

AUTH_KEY_HEX = "ab" * 32
auth_key_file = os.path.join(run, "flint-auth.key")
open(auth_key_file, "w", encoding="utf-8").write(AUTH_KEY_HEX + "\n")

flintd_store = os.path.join(run, "flintd-store")
os.makedirs(os.path.join(flintd_store, "streams"), exist_ok=True)
with open(os.path.join(flintd_store, "streams", gp_sid + ".jsonl"), "w") as f:
    f.write(gp_line + "\n")
with open(os.path.join(flintd_store, "streams", gp_sid + ".json"), "w") as f:
    f.write(json.dumps(gp_stream_rec, separators=(",", ":")) + "\n")
subprocess.run(["sh", "-c", "lsof -ti tcp:4859 | xargs kill -9"],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.2)
flintd_log = open(os.path.join(run, "flintd.log"), "wb")
flintd_proc = subprocess.Popen(
    [flintd, "serve", "--store=" + flintd_store,
     "--listen=127.0.0.1:4859", "--auth-key=" + auth_key_file],
    stdout=flintd_log, stderr=subprocess.STDOUT, start_new_session=True)
flintd_up = False
for _ in range(100):
    try:
        s = socket.create_connection(("127.0.0.1", 4859), 0.2)
        s.close()
        flintd_up = True
        break
    except OSError:
        if flintd_proc.poll() is not None:
            break
        time.sleep(0.1)
if not flintd_up:
    sys.exit("flintd did not come up on 127.0.0.1:4859 (see flintd.log)")
print("flintd: serving %s on 127.0.0.1:4859 pid=%d rev=%s"
      % (flintd_store, flintd_proc.pid, flintd_rev))

# paint-store-share: the store toolchain, a stock APPS.TXT, the first-party
# keyring pinning name=virelai only, the staged replica (release-sized
# Changes outrun the wire read — the go-flint seam), the signed channel
# drop, the one-byte-tampered DROPBAD, and the two .SH journeys.
store_share = os.path.join(run, "paint-store-share")
os.makedirs(os.path.join(store_share, "FLINT", "streams"), exist_ok=True)
os.makedirs(os.path.join(store_share, "FLINTJ"), exist_ok=True)
for name in ("GOSH.ELF", "STORE.ELF", "FLINT.ELF"):
    shutil.copy(os.path.join(".build", "go", name),
                os.path.join(store_share, name))
open(os.path.join(store_share, "SETTINGS.TXT"), "w", encoding="utf-8").write(
    "#v2\nwm=none\n")
open(os.path.join(store_share, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\nSTORE.ELF\t644\t0\t-\n")
open(os.path.join(store_share, "SECRETS.TXT"), "w", encoding="utf-8").write(
    "#v1\nflint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF\n")
open(os.path.join(store_share, "FLINT", "TRUSTED.TXT"),
     "w", encoding="utf-8").write(
    "#v1\nkey=" + gp_change["author"] + " name=virelai\n")
for suffix, body in ((".jsonl", gp_line + "\n"),
                     (".json", json.dumps(gp_stream_rec, separators=(",", ":")) + "\n")):
    with open(os.path.join(store_share, "FLINT", "streams", gp_sid + suffix), "w") as f:
        f.write(body)
shutil.copy(os.path.join("image", "apps.txt"),
            os.path.join(store_share, "APPS.TXT"))


def write_drop(drop, elf):
    d = os.path.join(store_share, drop, "gopaint")
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "release.go"), "w", encoding="utf-8").write(gp_go)
    open(os.path.join(d, "GOPAINT.ELF"), "wb").write(elf)


write_drop("DROP", gp_elf)
write_drop("DROPBAD", gp_elf + b"\x00")

# P4.SH leads with the iteration-boundary delete: iteration 1 honestly
# refuses not_installed, later iterations remove run 05's leftover so the
# install below is always a real install. GOPAINT.ELF is last — the run
# ends on its quit marker, not on anything the script could print early.
open(os.path.join(store_share, "FLINTJ", "P4.SH"), "w", encoding="utf-8").write(
    "STORE.ELF remove GOPAINT.ELF\n"
    "STORE.ELF ls --remote=10.0.0.2:4859 --channel=/host/DROP\n"
    "STORE.ELF install gopaint --remote=10.0.0.2:4859 --channel=/host/DROPBAD\n"
    "echo m141b: tamper refused\n"
    "STORE.ELF install gopaint --remote=10.0.0.2:4859 --channel=/host/DROP\n"
    "echo m141b: installed\n"
    "GOPAINT.ELF\n")
open(os.path.join(store_share, "FLINTJ", "P5.SH"), "w", encoding="utf-8").write(
    "STORE.ELF remove GOPAINT.ELF\n"
    "echo m141b: removed\n"
    "STORE.ELF install gopaint --remote=10.0.0.2:4859 --channel=/host/DROP\n"
    "echo m141b: reinstalled\n"
    "GOPAINT.ELF /host/PSTORE.QOI\n")
print("paint-store-share: signed gopaint release change=%s, DROP + DROPBAD"
      % gp_change["id"])
PY

# ---- run 04: install through STORE, tamper refused by name, draw + save ----
# exec-order: assert-proven -- the journey lives inside the gosh .SH; every
# assert reads program output (store/gopaint markers), and the run ends on
# the script's own rx echo only after the app exited.
vgate_run 04 -- \
    --screen '$RUN_DIR/paint-store-screen' \
    --input --via-virtio \
    --cvc-file '$RUN_DIR/paint-store-share' \
    --virtio-fs '$RUN_DIR/paint-store-share' \
    --net '$RUN_DIR/cap04.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4859:relay --net-tcp-respond-relay 127.0.0.1:4859 \
    --script '$RUN_DIR/script-04.txt' \
    --script2 '$RUN_DIR/script2-04.txt' \
    --script2-after 'VirelaiOS kernel has seized control.' \
    --pointer-virtio '50,255,d;50,255,u;128,96,d;248,96;248,196;248,196,u;52,89,d;52,89,u;328,96,d;408,176;408,176,u;52,115,d;52,115,u;388,256,d;548,376;548,376,u' \
    --pointer-virtio-after 'gopaint: ready' \
    --input-chords 'ctrl-s,P,S,T,O,R,E,.,Q,O,I,return,escape' \
    --input-chords-after 'gopaint: commit rect' \
    --script-expect 'gopaint: quit' --timeout 420

vgate_assert 04 serial-contains 'exec: loaded GOSH.ELF'
vgate_assert 04 serial-contains 'store: stream gopaint release name=GOPAINT version=1.0.0 category=app'
vgate_assert 04 serial-contains 'publisher_name=virelai publisher_state=trusted'
vgate_assert 04 serial-contains 'store: ls ok entries=1'
# The tampered payload refuses by name before any publish; the real
# install then runs every signed-pipeline leg.
vgate_assert 04 serial-contains 'store: refuse elf_mismatch GOPAINT.ELF'
vgate_assert 04 serial-contains 'm141b: tamper refused'
vgate_assert 04 serial-contains 'store: verified gopaint'
vgate_assert 04 serial-contains 'store: install ok GOPAINT.ELF version=1.0.0'
vgate_assert 04 serial-contains 'm141b: installed'
vgate_assert 04 serial-contains 'gopaint: open id='
vgate_assert 04 serial-contains 'gopaint: not-tab-aware'
vgate_assert 04 serial-contains 'gopaint: canvas 640x480'
vgate_assert 04 serial-contains 'gopaint: ready'
vgate_assert 04 serial-contains 'gopaint: color 9'
vgate_assert 04 serial-contains 'gopaint: commit brush n=1110 sum=2403da426d2b6a71'
vgate_assert 04 serial-contains 'gopaint: tool line'
vgate_assert 04 serial-contains 'gopaint: commit line n=413 sum=a6b92d65c02c3d9b'
vgate_assert 04 serial-contains 'gopaint: commit rect n=560 sum=e9449dcb31e7c11b'
vgate_assert 04 serial-contains 'gopaint: pick save /host/PSTORE.QOI'
vgate_assert 04 serial-contains 'gopaint: saved /host/PSTORE.QOI n=6190 sum=e9449dcb31e7c11b'
vgate_assert 04 serial-contains 'gopaint: quit'
vgate_assert 04 serial-absent 'gopaint: save refused'
vgate_assert 04 serial-absent 'gopaint: open refused'
vgate_assert 04 serial-absent 'store: refuse elf_exists'
vgate_assert 04 serial-absent 'store: refuse already_installed'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "paint-store-share")
ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")

# The installed binary is exactly what the signed release pins.
rel = open(os.path.join(share, "DROP", "gopaint", "release.go"),
           "r", encoding="utf-8").read()
head = 'const ReleaseELFSHA256 = "'
pin = ""
for line in rel.splitlines():
    if line.startswith(head):
        pin = line[len(head):line.rindex('"')]
if not pin:
    sys.exit("release.go missing ReleaseELFSHA256")
elf = os.path.join(share, "GOPAINT.ELF")
if not os.path.isfile(elf):
    sys.exit("GOPAINT.ELF missing at share root after install")
got = hashlib.sha256(open(elf, "rb").read()).hexdigest()
if got != pin:
    sys.exit("installed GOPAINT.ELF sha %s != signed pin %s" % (got, pin))

# Install self-registered exactly one manifest row; STORE.TXT tracks the
# stream and the declared caps.
apps = open(os.path.join(share, "APPS.TXT"), encoding="utf-8").read()
if apps.count("GOPAINT.ELF |") != 1:
    sys.exit("expected exactly one GOPAINT row in APPS.TXT: %r" % apps)
state = open(os.path.join(share, "STORE.TXT"), encoding="utf-8").read()
if "name=GOPAINT.ELF stream=gopaint" not in state:
    sys.exit("STORE.TXT missing the gopaint entry: %r" % state)
if "caps=file,window,memory,process,debug" not in state:
    sys.exit("STORE.TXT did not record the declared caps: %r" % state)

# The saved canvas hashes the class-A-pinned bytes.
data = open(os.path.join(share, "PSTORE.QOI"), "rb").read()
sha = hashlib.sha256(data).hexdigest()
if sha != "66cbfbcefc44ef6bd9c2ecdc00d3f50e6895503df260761cc60862a80d98744a":
    sys.exit("PSTORE.QOI sha256 %s" % sha)
if data[:4] != b"qoif":
    sys.exit("PSTORE.QOI not a QOI")
# The signing seed never reached the guest's serial transcript.
seed = open(os.path.join("user", "go", "flint", "testdata", "sig", "seed.hex"),
            "r", encoding="utf-8").read().strip()
if seed in ser:
    sys.exit("the publisher seed reached the serial log")
print("run-04: signed install + self-registered row + pinned save verified")
PY

# ---- run 05: remove -> reinstall -> reopen -> edit -> save -> remove -----
# exec-order: assert-proven -- same .SH shape as run 04; asserts read only
# program output, and the run ends on the script's own rx echo.
vgate_run 05 -- \
    --screen '$RUN_DIR/paint-store2-screen' \
    --input --via-virtio \
    --cvc-file '$RUN_DIR/paint-store-share' \
    --virtio-fs '$RUN_DIR/paint-store-share' \
    --net '$RUN_DIR/cap05.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4859:relay --net-tcp-respond-relay 127.0.0.1:4859 \
    --script '$RUN_DIR/script-05.txt' \
    --script2 '$RUN_DIR/script2-05.txt' \
    --script2-after 'VirelaiOS kernel has seized control.' \
    --pointer-virtio '76,255,d;76,255,u;52,141,d;52,141,u;444,272,d;444,272,u' \
    --pointer-virtio-after 'gopaint: ready' \
    --input-chords 'ctrl-s,return,escape' \
    --input-chords-after 'gopaint: commit fill' \
    --script-expect 'gopaint: quit' --timeout 420

vgate_assert 05 serial-contains 'exec: loaded GOSH.ELF'
vgate_assert 05 serial-contains 'store: remove GOPAINT.ELF'
vgate_assert 05 serial-contains 'store: remove ok GOPAINT.ELF'
vgate_assert 05 serial-contains 'm141b: removed'
vgate_assert 05 serial-contains 'store: verified gopaint'
vgate_assert 05 serial-contains 'store: install ok GOPAINT.ELF version=1.0.0'
vgate_assert 05 serial-contains 'm141b: reinstalled'
vgate_assert 05 serial-contains 'gopaint: loaded /host/PSTORE.QOI 640x480 sum=e9449dcb31e7c11b'
vgate_assert 05 serial-contains 'gopaint: color 11'
vgate_assert 05 serial-contains 'gopaint: tool fill'
vgate_assert 05 serial-contains 'gopaint: commit fill n=18921 sum=c80c07f96fb2d329'
vgate_assert 05 serial-contains 'gopaint: pick save /host/PSTORE.QOI'
vgate_assert 05 serial-contains 'gopaint: saved /host/PSTORE.QOI n=6193 sum=c80c07f96fb2d329'
vgate_assert 05 serial-contains 'gopaint: quit'
vgate_assert 05 serial-absent 'store: refuse'
vgate_assert 05 serial-absent 'gopaint: save refused'
vgate_assert 05 serial-absent 'gopaint: open refused'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
vgate_assert 05 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "paint-store-share")

# The re-saved canvas hashes the edited bytes (class-A pinned).
data = open(os.path.join(share, "PSTORE.QOI"), "rb").read()
sha = hashlib.sha256(data).hexdigest()
if sha != "416c5327f2456c708b4aeb8cc37b9c7dc567c7721aab0a4d9fb397bebc7fbefc":
    sys.exit("edited PSTORE.QOI sha256 %s" % sha)

# The reinstall stands (run 04 owns the iteration-boundary delete): one
# row, the pinned ELF, and the tracked state entry.
apps = open(os.path.join(share, "APPS.TXT"), encoding="utf-8").read()
if apps.count("GOPAINT.ELF |") != 1:
    sys.exit("expected exactly one GOPAINT row in APPS.TXT: %r" % apps)
elf = os.path.join(share, "GOPAINT.ELF")
if not os.path.isfile(elf):
    sys.exit("GOPAINT.ELF missing after reinstall")
state = open(os.path.join(share, "STORE.TXT"), encoding="utf-8").read()
if "name=GOPAINT.ELF stream=gopaint" not in state:
    sys.exit("STORE.TXT lost the gopaint entry: %r" % state)
print("run-05: reinstall + reopen + edit + save verified")
PY
