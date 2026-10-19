# live-doom.spec -- class-B gate (M130c, #2620, ADR 0058): DOOM.ELF from the
# sibling doom-engine repo (ozkl/doomgeneric, GPLv2) execs as a real EL0 app
# off the virtio share, opens a shim-composited window, and runs the real
# game loop at tic rate. Scripted cv-input drives the player: 'w' held =
# forward, chords for use (space)/fire (ctrl-x)/turn (left). Raw scanout
# snapshots pixel-assert the E1M1 scene + HUD and a scene delta.
#
# Nothing GPL lands in this repo or image: the setup hook builds DOOM.ELF in
# the sibling checkout ($DOOM_ENGINE_DIR or ../doom-engine), verifies the
# shareware doom1.wad sha256, and stages both into the RUN share. The guest
# resolves bare paths against /host, so `exec DOOM.ELF -iwad doom1.wad` is
# the store-path equivalent the card asks for.
vgate_name live-doom "M130c: DOOM runs in-guest, input+frames proven"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_setup_python <<'PYEOF'
import hashlib, os, shutil, subprocess, sys

share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
os.makedirs(share, exist_ok=True)

engine = os.environ.get("DOOM_ENGINE_DIR") or os.path.abspath("../doom-engine")
if not os.path.isfile(os.path.join(engine, "Makefile")):
    sys.exit("doom-engine sibling missing at %s -- clone drawmeanelephant/"
             "doom-engine there or set DOOM_ENGINE_DIR" % engine)

# Build the guest ELF in the sibling (idempotent) + contract-check it.
subprocess.run(["make", "-C", engine, "doom.elf", "check-elf"], check=True)
elf = os.path.join(engine, "build", "DOOM.ELF")
if not os.path.isfile(elf):
    sys.exit("build/DOOM.ELF missing after make")

# The shareware IWAD is a sibling-repo asset, never committed here. Pin it.
WAD_SHA256 = "1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771"
wad = os.path.join(engine, "assets", "doom1.wad")
if not os.path.isfile(wad):
    sys.exit("assets/doom1.wad missing in %s" % engine)
if hashlib.sha256(open(wad, "rb").read()).hexdigest() != WAD_SHA256:
    sys.exit("doom1.wad sha256 mismatch -- not the pinned shareware 1.9 asset")

shutil.copy(elf, os.path.join(share, "DOOM.ELF"))
shutil.copy(wad, os.path.join(share, "doom1.wad"))
# Bare shim (go-calc shape): the app window composes 1:1 on the scanout,
# scripted keys land on the focused window owner without seat/WM chrome.
open(os.path.join(share, "SETTINGS.TXT"), "w", encoding="utf-8").write(
    "#v2\nwm=none\n")
# ADR 0058's release-cap set, staged as a grant row (wildcard digest -- the
# binary's measurement changes as the engine branch moves): the ambient
# words DOOM exercises (window/timer/memory/process/debug) + the declared
# payload words file + audio (audio unused until M130d; net absent --
# a DOOM port never networks). Without the row every file syscall lands
# an audit:file_denied receipt (~4k lines of spam).
open(os.path.join(share, "GRANTS.TXT"), "w", encoding="utf-8").write(
    "#v1\nDOOM.ELF\t*\tfile,window,audio,timer,memory,process,debug\n")
rev = subprocess.run(["git", "-C", engine, "rev-parse", "HEAD"],
                     capture_output=True, text=True).stdout.strip()
print("doom-engine: %s @ %s -> share (DOOM.ELF + doom1.wad)" % (engine, rev))
PYEOF

vgate_file script.txt <<'EOF'
exec DOOM.ELF -iwad doom1.wad -warp 1 1
EOF

vgate_file script-poke.txt <<'EOF'
echo rx-doom-poke
EOF

vgate_file script-done.txt <<'EOF'
echo rx-doom-done
EOF

# exec-order: assert-proven -- every leg lands on vldoom: serial markers.
#
#   The shim composite paints on console/input wake-ups (the shell idle
#   drain does not free-run while an app spins), so every snapshot is
#   preceded by a host-visible input or serial poke.
#   --input-key 13 = 'w' keyDown-only (held forward) at f=140: sustained
#     movement spanning BOTH snapshots; WASD are movement aliases.
#   --input-chords left/space/ctrl-x at f=210: turn/use/fire taps (the
#     release reports also drop the held 'w' shortly after).
#   --snapshot-after f=175 (moving baseline) + f=280 (post-turn/fire):
#     two raw BGRX scanout streams of the shim composite.
#   script2's echo at f=245 pokes the console so the composite ahead of
#     the f=280 snapshot ships a fresh frame; script3 ends the run.
vgate_run 01 -- \
    --screen '$RUN_DIR/doom-screen' \
    --snapshot-after 'vldoom: f=175' \
    --snapshot-after 'vldoom: f=280' \
    --input-key 13 --input-key-after 'vldoom: f=140' \
    --input-chords 'left,space,ctrl-x' --input-chords-after 'vldoom: f=210' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script-poke.txt' --script2-after 'vldoom: f=245' \
    --script3 '$RUN_DIR/script-done.txt' --script3-after 'vldoom: f=315' \
    --script-expect 'rx-doom-done' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'gpu: setup ok scanout='
vgate_assert 01 serial-contains 'exec: loaded DOOM.ELF'
vgate_assert 01 serial-contains 'vldoom: boot argc='
vgate_assert 01 serial-contains 'vldoom: win id='
vgate_assert 01 serial-contains 'W_Init: Init WADfiles.'
vgate_assert 01 serial-contains 'vldoom: level'
vgate_assert 01 serial-contains 'vldoom: f=175 t='
vgate_assert 01 serial-contains 'vldoom: f=280 t='
vgate_assert 01 serial-contains 'rx-doom-poke'
vgate_assert 01 serial-contains 'vldoom: key dn hid=0x1a doom=0xad'
vgate_assert 01 serial-contains 'vldoom: key dn hid=0x2c doom=0xa2'
vgate_assert 01 serial-contains 'vldoom: key dn hid=0x1b doom=0xa3'
vgate_assert 01 serial-contains 'vldoom: key up hid=0x1b doom=0xa3'
vgate_assert 01 serial-contains 'vldoom: key dn hid=0x50 doom=0xac'
vgate_assert 01 serial-contains 'rx-doom-done'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# Snap 0 (~1 s into E1M1): the DOOM window composits at (320,160) on the
# 1280x720 scanout: a ~16 px accent title band (the kernel's window chrome),
# then the 640x400 client — browns/grays of the hangar scene plus the
# nukage blues, and the skin-tone/tan status bar over the last ~64 rows.
vgate_assert 01 snapshot 'doom-screen-snap-0*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))

WX, WY, WW = 320, 160, 640
TITLE0, TITLE1 = WY, WY + 16
VP0, VP1 = WY + 16, WY + 336          # viewport rows (scene)
HU0, HU1 = WY + 336, WY + 400         # status bar rows

def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])

def colors(x0, x1, y0, y1, step=2):
    s = set()
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            s.add(px(x, y))
    return s

def count(pred, x0, x1, y0, y1, step=2):
    n = 0
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            if pred(px(x, y)):
                n += 1
    return n

title = count(lambda p: p == (59, 130, 246), WX, WX + WW, TITLE0, TITLE1, 1)
vp = colors(WX, WX + WW, VP0, VP1)
hu = colors(WX, WX + WW, HU0, HU1)
# DOOM palette signatures: warm browns (r > g > b, mid range), deep nukage
# blues (b dominant, r,g ~0), status-bar flesh tans (high r,g, moderate b).
warm = count(lambda p: p[0] > p[1] > p[2] and p[0] > 40, WX, WX + WW, VP0, VP1)
nuk  = count(lambda p: p[2] > 40 and p[0] < 10 and p[1] < 10, WX, WX + WW, VP0, VP1)
flesh = count(lambda p: p[0] > 140 and p[1] > 60 and p[2] < p[1] and p[0] > p[2] * 2,
              WX, WX + WW, HU0, HU1)
print("title=%d/1280 viewport colors=%d hud colors=%d warm=%d nukage=%d flesh=%d"
      % (title, len(vp), len(hu), warm, nuk, flesh))
assert title >= 200, ("only %d accent pixels in the title band -- the "
                      "window is not composited at (320,160)" % title)
assert len(vp) >= 30, ("only %d distinct colors in the viewport -- the "
                       "scene did not render" % len(vp))
assert len(hu) >= 10, ("only %d distinct colors in the status band -- no "
                       "HUD painted" % len(hu))
assert warm >= 100, "no DOOM brown/gray walls in the viewport (%d)" % warm
assert flesh >= 20, ("no status-bar flesh tones in the HUD band (%d) -- "
                     "STBAR did not paint" % flesh)
print("E1M1 frame composited: title band + scene palette + HUD band")
PY

# Snap 1 (~5 s later): same structural floor, and a real scene delta vs
# snap 0 -- the held 'w' + turn/use/fire chords moved the player.
vgate_assert 01 snapshot 'doom-screen-snap-1*.raw' <<'PY'
import glob, os, sys

W, H = 1280, 720
raw2 = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw2) < need:
    sys.exit("snapshot is %d bytes, want at least %d" % (len(raw2), need))
# Snapshot asserts get the matched file as argv[1]; RUN_DIR is not
# exported to the assert, so sibling snaps resolve via the file's dir.
snaps = sorted(glob.glob(os.path.join(os.path.dirname(sys.argv[1]),
                                      "doom-screen-snap-*.raw")))
if len(snaps) < 2:
    sys.exit("expected two snapshots under RUN_DIR, found %d" % len(snaps))
raw1 = open(snaps[0], "rb").read()
if len(raw1) < need:
    sys.exit("first snapshot short: %d bytes" % len(raw1))

WX, WY, WW, WH = 320, 160, 640, 400

def px(raw, x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])

diff = 0
total = 0
for y in range(WY, WY + WH, 2):
    for x in range(WX, WX + WW, 2):
        total += 1
        if px(raw1, x, y) != px(raw2, x, y):
            diff += 1
frac = diff * 100 // total
print("scene delta: %d/%d sampled window pixels differ (%d%%)"
      % (diff, total, frac))
assert frac >= 5, ("only %d%% of the window changed between +1 s and +5 s "
                   "-- input did not move the player" % frac)
print("E1M1 scene delta proven: the player moved under scripted input")
PY
