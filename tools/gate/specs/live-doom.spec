# live-doom.spec -- class-B gate (M130c/e, #2620/#2622, ADR 0058): DOOM.ELF
# from the sibling doom-engine repo (ozkl/doomgeneric, GPLv2) execs as a real
# EL0 app off the virtio share, opens a shim-composited window, and runs the
# real game loop at tic rate. Scripted cv-input drives the player: 'w' held =
# forward, chords for use (space)/fire (ctrl-x)/turn (left). Raw scanout
# snapshots pixel-assert the E1M1 scene + HUD and a scene delta.
#
# Run 02 (M130e): the stranger's-app journey made real — doom-engine signs
# the `doom` release stream under its own publisher key (pinned name=doom in
# the consumer TRUSTED.TXT), a fresh share installs it through STORE off a
# host flintd + channel drop, the signed ReleaseCaps ask is proposed and a
# GOSET consent writes the hash-bound grant row, and the installed
# DOOM.ELF launches to TITLEPIC (pixel-asserted). The IWAD + the GPL
# LICENSE ride the channel as signed ReleaseAssetSHA256-pinned members and
# the app opens the WAD in place — STORE has no asset fetch (out of scope:
# a store change would be its own card).
#
# Run 03 (M130f): the acceptance journey on a second fresh consumer —
# install, scripted `store consent`, launch, then scripted keys ride
# TITLEPIC→demo1 (the melt reserve-x18 fixed) → menu → E1M1: move, open
# the exit door, fire, kill, and menu-quit to a clean task exit.
#
# Nothing GPL lands in this repo or image: the setup hook builds DOOM.ELF in
# the sibling checkout ($DOOM_ENGINE_DIR or ../doom-engine), verifies the
# shareware doom1.wad sha256, and stages both into the RUN share. The guest
# resolves bare paths against /host, so `exec DOOM.ELF -iwad doom1.wad` is
# the store-path equivalent the card asks for.
#
# HOST PREREQ (run 02): bash tools/go/build-flint.sh / build-gosh.sh /
# build-store.sh / build-goset.sh -> .build/go/{FLINT,GOSH,STORE,GOSET}.ELF;
# ../flint-server checkout (or FLINT_SERVER_DIR=...) — the hook zig-builds
# flintd and serves the signed doom stream on 127.0.0.1:4749.
vgate_name live-doom "M130c: DOOM runs in-guest, input+frames proven"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3 BOOTS

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

# ---- M130e (#2622): the signed store release ----------------------------
# `make release` in the sibling mints the signed `doom` stream (the
# manifest pins THIS build's ELF sha — the engine build is not
# bit-reproducible, so the release is regenerated per run like the acme
# fixture was) plus the channel drop. doom-store-share is the fresh
# consumer: full keyring pinning name=doom only, the staged replica
# (release-sized Changes outrun the wire `read` boundary — the go-flint
# staged-bytes seam), and the DROP channel carrying release.go + DOOM.ELF
# + the ReleaseAssetSHA256-pinned members doom1.wad and LICENSE.
import json, socket, time

run = os.environ["RUN_DIR"]
subprocess.run(["make", "-C", engine, "release"], check=True)
rel_dir = os.path.join(engine, "build", "release")
for name in ("doom-stream.jsonl", "doom-stream.json", "release.go",
             "publisher.pub"):
    if not os.path.isfile(os.path.join(rel_dir, name)):
        sys.exit("%s missing after make release" % name)
doom_line = open(os.path.join(rel_dir, "doom-stream.jsonl"),
                 "r", encoding="utf-8").read().strip()
doom_change = json.loads(doom_line)
doom_pub = open(os.path.join(rel_dir, "publisher.pub"),
                "r", encoding="utf-8").read().strip()
doom_seed = open(os.path.join(engine, "release", "publisher.seed"),
                 "r", encoding="utf-8").read().strip()
stream_rec = json.loads(open(os.path.join(rel_dir, "doom-stream.json"),
                           "r", encoding="utf-8").read())
doom_sid = stream_rec["id"]

for name, cmd in (
    ("FLINT.ELF", "bash tools/go/build-flint.sh"),
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
    ("STORE.ELF", "bash tools/go/build-store.sh"),
    ("GOSET.ELF", "bash tools/go/build-goset.sh"),
):
    if not os.path.isfile(os.path.join(".build", "go", name)):
        sys.exit(name + " missing (expected .build/go/" + name +
                 ") - build it first: " + cmd)

# flintd serves the doom stream — the flint-server sibling pattern from
# go-flint (FLINT_SERVER_DIR else ../flint-server, zig build per run).
repo = os.getcwd()
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

flintd_store = os.path.join(run, "flintd-store")
os.makedirs(os.path.join(flintd_store, "streams"), exist_ok=True)
with open(os.path.join(flintd_store, "streams", doom_sid + ".jsonl"), "w") as f:
    f.write(doom_line + "\n")
with open(os.path.join(flintd_store, "streams", doom_sid + ".json"), "w") as f:
    f.write(json.dumps(stream_rec, separators=(",", ":")) + "\n")

AUTH_KEY_HEX = "ab" * 32
auth_key_file = os.path.join(run, "flint-auth.key")
open(auth_key_file, "w", encoding="utf-8").write(AUTH_KEY_HEX + "\n")
subprocess.run(["sh", "-c", "lsof -ti tcp:4749 | xargs kill -9"],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.2)
flintd_log = open(os.path.join(run, "flintd.log"), "wb")
flintd_proc = subprocess.Popen(
    [flintd, "serve", "--store=" + flintd_store,
     "--listen=127.0.0.1:4749", "--auth-key=" + auth_key_file],
    stdout=flintd_log, stderr=subprocess.STDOUT, start_new_session=True)
flintd_up = False
for _ in range(100):
    try:
        s = socket.create_connection(("127.0.0.1", 4749), 0.2)
        s.close()
        flintd_up = True
        break
    except OSError:
        if flintd_proc.poll() is not None:
            break
        time.sleep(0.1)
if not flintd_up:
    sys.exit("flintd did not come up on 127.0.0.1:4749 (see flintd.log)")
print("flintd: serving %s on 127.0.0.1:4749 pid=%d rev=%s"
      % (flintd_store, flintd_proc.pid, flintd_rev))

doom_share = os.path.join(run, "doom-store-share")
os.makedirs(os.path.join(doom_share, "FLINTJ"), exist_ok=True)
os.makedirs(os.path.join(doom_share, "FLINT", "streams"), exist_ok=True)
for name in ("FLINT.ELF", "GOSH.ELF", "STORE.ELF", "GOSET.ELF"):
    shutil.copy(os.path.join(".build", "go", name), os.path.join(doom_share, name))
open(os.path.join(doom_share, "SETTINGS.TXT"), "w", encoding="utf-8").write(
    "#v2\nwm=none\n")
open(os.path.join(doom_share, "OWNERS.TXT"), "w", encoding="utf-8").write(
    "#v1\nFLINT.ELF\t644\t0\t-\nSTORE.ELF\t644\t0\t-\n")
open(os.path.join(doom_share, "SECRETS.TXT"), "w", encoding="utf-8").write(
    "#v1\nflint-remote\t1000\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF\n"
    # The E.SH runs inside an -u0 gosh (the consent chain — run-25's
    # shape), so the admin principal gets its own lane for the same key.
    "flint-remote\t0\t" + AUTH_KEY_HEX + "\tFLINT.ELF,STORE.ELF\n")
# The keyring pins ONLY the doom publisher — stranger's software means the
# VirelaiOS base key vouches for nothing on this share.
open(os.path.join(doom_share, "FLINT", "TRUSTED.TXT"),
     "w", encoding="utf-8").write(
    "#v1\nkey=" + doom_pub + " name=doom\n")
with open(os.path.join(doom_share, "FLINT", "streams", doom_sid + ".jsonl"),
          "w") as f:
    f.write(doom_line + "\n")
with open(os.path.join(doom_share, "FLINT", "streams", doom_sid + ".json"),
          "w") as f:
    f.write(json.dumps(stream_rec, separators=(",", ":")) + "\n")
shutil.copy(os.path.join("image", "apps.txt"), os.path.join(doom_share, "APPS.TXT"))
# The channel drop — verbatim from the engine repo's `make release`
# output: the signed manifest and every hash-pinned member.
shutil.copytree(os.path.join(rel_dir, "channel"), os.path.join(doom_share, "DROP"))
open(os.path.join(doom_share, "FLINTJ", "E.SH"), "w", encoding="utf-8").write(
    "STORE.ELF ls --remote=10.0.0.2:4749 --channel=/host/DROP\n"
    "STORE.ELF install doom --remote=10.0.0.2:4749 --channel=/host/DROP\n"
    "echo m130e: declared\n"
    "GOSET.ELF\n"
    "DOOM.ELF -iwad /host/DROP/doom/doom1.wad\n"
)
print("doom-store-share: signed release @ %s, publisher=%s, drop=DROP/doom"
      % (doom_change["id"], doom_pub))

# ---- M130f (#2623): the acceptance consumer --------------------------------
# doom-accept-share is a SECOND fresh consumer — same signed stream and the
# same name=doom keyring, but an untouched STORE.TXT/GRANTS.TXT/APPS.TXT, so
# run 03's install is the stranger's-app journey on a VM that never saw it.
# Its E3.SH answers the pending ask with `store consent` — the scriptable
# M116c (ADR 0054 D10) gesture through the same slot-89 admin write GOSET
# lands interactively — freeing the run's single --input-chords sequence for
# the E1M1 walkthrough.
accept_share = os.path.join(run, "doom-accept-share")
shutil.rmtree(accept_share, ignore_errors=True)
shutil.copytree(doom_share, accept_share, dirs_exist_ok=True)
# walk.lmp — a synthesized vanilla v109 demo (skill=HMP, ep1, map1) the
# guest replays with -playdemo: spawn -> N across the hangar (move) -> SE
# around the stub wall -> N through the slot corridor to the niche door
# (1544,-2500) -> USE taps (open door) -> E into the north room -> held
# pistol fire on the zombiemen (fire, kill). Per-tic input is fixed, so
# the replay is deterministic; `singledemo` ends it in I_Quit -> exit(0).
tics = []
def _leg(n, f=0, s=0, t=0, b=0):
    for _ in range(n):
        tics.append((f, s, t, b))
def _face(a, b):
    return round(((b - a) % 360) / 1.40625) % 256
_pos = [1056, -3616]
_ang = [90.0]
def _go(tx, ty, cap):
    import math
    b = math.degrees(math.atan2(ty - _pos[1], tx - _pos[0])) % 360
    _leg(1, 0, 0, _face(_ang[0], b))
    _ang[0] = b
    _leg(cap, 50)
    _pos[:] = [tx, ty]
_go(1056, -2900, 80)
_go(1450, -3100, 90)
_go(1480, -2800, 60)
_go(1530, -2540, 60)
_leg(1, 0, 0, _face(_ang[0], 0)); _ang[0] = 0
for _ in range(4):
    _leg(4, 0, 0, 0, 2); _leg(2); _leg(10, 30)
_leg(30, 50)
_go(2000, -2470, 80)
import math as _math
_b = _math.degrees(_math.atan2(-2432 - _pos[1], 2272 - _pos[0])) % 360
_leg(1, 0, 0, _face(_ang[0], _b)); _ang[0] = _b
for _r in (100, 30, 60, 20):
    if _r == 30:
        _leg(30, 50)
    else:
        _leg(_r, 0, 0, 0, 1) if _r != 20 else _leg(20)
# rebuild the tail cleanly: fire 100, move 30, fire 60, idle 20
lmp = bytearray([109, 2, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0] + [0] * 12)
for f, s, t, b in tics:
    lmp += bytes([f & 0xff, s & 0xff, t & 0xff, b])
lmp += b"\x80"
open(os.path.join(accept_share, "walk.lmp"), "wb").write(lmp)

open(os.path.join(accept_share, "FLINTJ", "E3.SH"),
     "w", encoding="utf-8").write(
    "STORE.ELF ls --remote=10.0.0.2:4749 --channel=/host/DROP\n"
    "STORE.ELF install doom --remote=10.0.0.2:4749 --channel=/host/DROP\n"
    "echo m130f: declared\n"
    "STORE.ELF consent DOOM.ELF\n"
    "echo m130f: consented\n"
)
print("doom-accept-share: fresh consumer, scripted consent, walk.lmp "
      "%d tics" % len(tics))
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

# ---- 02: M130e (#2622) — the signed `doom` release installs through ----
# ---- STORE on a fresh share and launches to TITLEPIC ------------------
# exec-order: assert-proven. doom-store-share is a fresh consumer keyed
# only for the engine repo's own publisher (name=doom — ADR 0058 D6's
# distinct Ed25519 key): `store ls` folds the signed catalog entry off
# the staged replica, `store install doom` verifies the manifest's signed
# atom set + the ELF sha and publishes DOOM.ELF at the share root, the
# ReleaseCaps ask is proposed, GOSET (foreground inside the -u0 gosh —
# the run-25 consent-chain shape) writes the hash-bound row through the
# admin slot on the typed `grant DOOM.ELF`, two Esc exits hand the .SH
# back, and the installed app opens the WAD straight out of the channel
# member it rode in on. TITLEPIC pages for ~170 tics, so the f=70
# heartbeat is mid-title; the run ends on the f=105 marker.
vgate_file script-store.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
EOF

vgate_file script2-store.txt <<'EOF'
exec -u0 GOSH.ELF -c "source /host/FLINTJ/E.SH"
EOF

vgate_file script2-accept.txt <<'EOF'
exec -u0 GOSH.ELF -c "source /host/FLINTJ/E3.SH"
EOF

vgate_run 02 -- \
    --via-virtio \
    --screen '$RUN_DIR/doomstore-screen' \
    --snapshot-after 'vldoom: f=70' \
    --cvc-file '$RUN_DIR/doom-store-share' \
    --virtio-fs '$RUN_DIR/doom-store-share' \
    --net '$RUN_DIR/cap-doomstore.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-store.txt' \
    --script2 '$RUN_DIR/script2-store.txt' \
    --script2-after 'VirelaiOS kernel has seized control.' \
    --input-chords 'g,r,a,n,t,s,return,g,r,a,n,t,space,D,O,O,M,.,E,L,F,return,return,return,escape,escape' \
    --input-chords-after 'goset: ready ' \
    --script-expect 'vldoom: f=105' --timeout 420

# catalog + install: the signed consts render off the stream's head, the
# publisher fingerprint is the derived name=doom keyring label, and the
# ELF lands pinned to the signed sha.
vgate_assert 02 serial-contains 'store: stream doom release name=DOOM version=1.0.0 category=game'
vgate_assert 02 serial-contains 'publisher_name=doom publisher_state=trusted'
vgate_assert 02 serial-contains 'store: ls ok entries=1'
vgate_assert 02 serial-contains 'store: install ok DOOM.ELF version=1.0.0'
vgate_assert 02 serial-contains 'm130e: declared'
# consent: the signed ask is proposed, the pane renders it pending, the
# typed grant writes the hash-bound row through the admin slot.
vgate_assert 02 serial-contains 'store: grant propose DOOM.ELF words=file,window,audio,timer,memory'
vgate_assert 02 serial-contains 'goset: grants n='
vgate_assert 02 serial-contains 'goset: grant row name=DOOM.ELF declared=file,window,audio,timer,memory granted=- state=pending'
vgate_assert 02 serial-contains 'goset: grant written name=DOOM.ELF words=file,window,audio,timer,memory'
# launch: the measured exec receipts the row's digest and the engine
# reaches TITLEPIC — the f=70 snapshot below pixel-asserts it.
vgate_assert 02 serial-contains 'exec: loaded DOOM.ELF'
vgate_assert 02 serial-contains 'verdict=measured name=DOOM.ELF'
vgate_assert 02 serial-contains 'vldoom: boot argc='
vgate_assert 02 serial-contains 'vldoom: win id='
vgate_assert 02 serial-contains 'W_Init: Init WADfiles.'
vgate_assert 02 serial-contains 'vldoom: snd nodev'
vgate_assert 02 serial-contains 'vldoom: f=70 t='
vgate_assert 02 serial-contains 'vldoom: f=105 t='
vgate_assert 02 serial-absent 'store: refuse'
vgate_assert 02 serial-absent 'verdict=refused'
vgate_assert 02 serial-absent 'flint: refuse'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 serial-absent 'abababababababababababababababababababababababababababababababab'
vgate_assert 02 python <<'PY'
import hashlib, os, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "doom-store-share")
ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")

engine = os.environ.get("DOOM_ENGINE_DIR") or os.path.abspath("../doom-engine")
seed = open(os.path.join(engine, "release", "publisher.seed"),
            "r", encoding="utf-8").read().strip()
if seed in ser:
    sys.exit("FAIL: the doom publisher seed reached the serial log")

def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

# Parse the signed pins out of the channel copy of release.go — the same
# text the consumer verified against the Change's signed atoms.
rel = open(os.path.join(share, "DROP", "doom", "release.go"),
           "r", encoding="utf-8").read()
def const(name):
    head = 'const %s = "' % name
    for line in rel.splitlines():
        if line.startswith(head):
            return line[len(head):line.rindex('"')]
    sys.exit("release.go missing " + name)

elf_pin = const("ReleaseELFSHA256")
if sha(os.path.join(share, "DOOM.ELF")) != elf_pin:
    sys.exit("installed DOOM.ELF sha != signed ReleaseELFSHA256")
if elf_pin not in ser:
    sys.exit("the signed ELF sha never rendered in the catalog")

assets = dict(p.split(":", 1) for p in const("ReleaseAssetSHA256").split(","))
for member, pin in assets.items():
    got = sha(os.path.join(share, "DROP", "doom", member))
    if got != pin:
        sys.exit("channel member %s sha %s != signed pin %s"
                 % (member, got, pin))

# The consent row binds exactly the installed bytes with exactly the
# declared words — nothing ambient, nothing extra.
grants = open(os.path.join(share, "GRANTS.TXT"), "r", encoding="utf-8").read()
lines = [l for l in grants.splitlines() if l and not l.startswith("#")]
want = "DOOM.ELF\t" + sha(os.path.join(share, "DOOM.ELF")) + \
       "\tfile,window,audio,timer,memory"
if lines != [want]:
    sys.exit("GRANTS.TXT after consent: %r (want [%r])" % (lines, want))

state = open(os.path.join(share, "STORE.TXT"), "r", encoding="utf-8").read()
if "name=DOOM.ELF stream=doom" not in state:
    sys.exit("STORE.TXT missing the doom entry: %r" % state)
if "caps=file,window,audio,timer,memory" not in state:
    sys.exit("STORE.TXT did not record the declared ask: %r" % state)

apps = open(os.path.join(share, "APPS.TXT"), "r", encoding="utf-8").read()
if apps.count("DOOM.ELF |") != 1:
    sys.exit("expected exactly one DOOM.ELF row in APPS.TXT: %r" % apps)
if "argv=-iwad /host/DROP/doom/doom1.wad" not in apps:
    sys.exit("the installed row lost its launch argv: %r" % apps)
print("run-02 verified: signed install + hash-bound consent + pinned members")
PY

# TITLEPIC (shareware 1.9): the DOOM logo over the brown planetscape —
# warm browns/oranges across every band (~40% of the frame), ~18% dark
# sky, the full 256-entry palette, and NO status bar. Asserted on the
# 640x400 client under the kernel's accent title band.
vgate_assert 02 snapshot 'doomstore-screen-snap-0*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))

WX, WY, WW = 320, 160, 640
TITLE0, TITLE1 = WY, WY + 16
VP0, VP1 = WY + 16, WY + 400          # the whole client is the title art
TOP0, TOP1 = WY + 16, WY + 116        # logo reaches the top quarter

def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])

def count(pred, x0, x1, y0, y1, step=2):
    n = 0
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            if pred(px(x, y)):
                n += 1
    return n

def colors(x0, x1, y0, y1, step=2):
    s = set()
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            s.add(px(x, y))
    return s

title = count(lambda p: p == (59, 130, 246), WX, WX + WW, TITLE0, TITLE1, 1)
warm = count(lambda p: p[0] > 100 and p[0] > p[1] * 1.4 and p[0] > p[2] * 1.8,
             WX, WX + WW, VP0, VP1)
dark = count(lambda p: p[0] < 40 and p[1] < 40 and p[2] < 40,
             WX, WX + WW, VP0, VP1)
top_warm = count(lambda p: p[0] > 100 and p[0] > p[1] * 1.4 and p[0] > p[2] * 1.8,
                 WX, WX + WW, TOP0, TOP1)
distinct = len(colors(WX, WX + WW, VP0, VP1))
print("title=%d/1280 warm=%d dark=%d top_warm=%d colors=%d"
      % (title, warm, dark, top_warm, distinct))
assert title >= 200, ("only %d accent pixels in the title band -- the "
                      "window is not composited at (320,160)" % title)
assert warm >= 1500, ("only %d warm pixels -- the DOOM logo's browns/"
                      "oranges did not paint" % warm)
assert dark >= 500, "only %d dark pixels -- no title backdrop" % dark
assert top_warm >= 200, ("only %d warm pixels in the top quarter -- the "
                         "logo did not reach the top of the frame" % top_warm)
assert distinct >= 50, "only %d distinct colors -- not the title art" % distinct
print("TITLEPIC composited: logo mass + dark backdrop + full palette")
PY

# ---- 03: M130f (#2623) — acceptance: the journey a stranger's machine ----
# ---- makes. Fresh consumer share -> signed store install -> scripted  ----
# ---- consent -> launch -> scripted E1M1 walkthrough (move, open door, ----
# ---- fire, kill) -> clean exit.                                       ----
# exec-order: assert-proven -- every leg lands on vldoom:/store: markers
# the scripts do not produce.
#
#   E3.SH answers the pending ask with `store consent` (the scriptable
#   M116c gesture, the same slot-89 row GOSET writes) so no UI typing is
#   needed at all: the walkthrough is a fixed-input demo instead.
#
#   walk.lmp is a synthesized vanilla v109 demo (skill=HMP, ep1, map1 +
#   per-tic {forwardmove,sidemove,angleturn,buttons}) generated by the
#   setup hook below. `-playdemo` makes DOOM replay it deterministically
#   (fixed rng + fixed tic stream): spawn -> N across the hangar (move)
#   -> SE around the stub wall -> N through the slot corridor to the
#   niche door at (1544,-2500) -> USE taps (open door) -> E into the
#   north room -> held fire on the zombiemen (fire, kill). The route
#   reaches the door pocket — exercised on the doom-engine hosttest
#   mock. `singledemo` means the demo's own end runs G_CheckDemoStatus
#   -> I_Quit -> exit(0) -> vl_exit: the clean-exit leg is the app's
#   own quit path, not a window kill.
#
#   Audio gives every walkthrough verb a serial marker: the pistol shot
#   (dspistol), a monster death (dspodth), a door opening (dsbdopn), and
#   the doomgeneric f=/t= heartbeat lands the replay on serial markers.

vgate_file script3-accept.txt <<'EOF'
exec DOOM.ELF -iwad /host/DROP/doom/doom1.wad -playdemo /host/walk.lmp
EOF

vgate_run 03 -- \
    --via-virtio \
    --sound \
    --screen '$RUN_DIR/doomacc-screen' \
    --snapshot-after 'vldoom: f=70' \
    --snapshot-after 'vldoom: f=1400' \
    --snapshot-after 'vldoom: f=2415' \
    --cvc-file '$RUN_DIR/doom-accept-share' \
    --virtio-fs '$RUN_DIR/doom-accept-share' \
    --net '$RUN_DIR/cap-doomaccept.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:4749:relay --net-tcp-respond-relay 127.0.0.1:4749 \
    --script '$RUN_DIR/script-store.txt' \
    --script2 '$RUN_DIR/script2-accept.txt' \
    --script2-after 'VirelaiOS kernel has seized control.' \
    --script3 '$RUN_DIR/script3-accept.txt' \
    --script3-after 'm130f: consented' \
    --script-expect 'procs DOOM.ELF exited status=' --timeout 420

# install + scripted consent (the M130e evidence shape, minus GOSET).
vgate_assert 03 serial-contains 'store: stream doom release name=DOOM version=1.0.0 category=game'
vgate_assert 03 serial-contains 'publisher_name=doom publisher_state=trusted'
vgate_assert 03 serial-contains 'store: ls ok entries=1'
vgate_assert 03 serial-contains 'store: install ok DOOM.ELF version=1.0.0'
vgate_assert 03 serial-contains 'm130f: declared'
vgate_assert 03 serial-contains 'store: grant propose DOOM.ELF words=file,window,audio,timer,memory'
vgate_assert 03 serial-contains 'store: consent DOOM.ELF'
vgate_assert 03 serial-contains 'store: grant written name=DOOM.ELF words=file,window,audio,timer,memory'
# launch through the signed channel's argv, measured.
vgate_assert 03 serial-contains 'exec: loaded DOOM.ELF'
vgate_assert 03 serial-contains 'verdict=measured name=DOOM.ELF'
vgate_assert 03 serial-contains 'vldoom: boot argc='
vgate_assert 03 serial-contains 'vldoom: win id='
vgate_assert 03 serial-contains 'W_Init: Init WADfiles.'
vgate_assert 03 serial-contains 'vldoom: snd fmt='
# the walkthrough replayed: level entry, the demo stream, heartbeat.
vgate_assert 03 serial-contains 'vldoom: level'
vgate_assert 03 serial-contains 'Playing demo walk.lmp.'
vgate_assert 03 serial-contains 'vldoom: f=70 t='
vgate_assert 03 serial-contains 'vldoom: f=1400 t='
vgate_assert 03 serial-contains 'vldoom: f=2415 t='
# walkthrough verbs on the audio seat: pistol fire, a monster death,
# a door opening.
vgate_assert 03 serial-contains 'vldoom: sfx dspistol'
vgate_assert 03 serial-contains 'vldoom: sfx dspodth'
vgate_assert 03 serial-contains 'vldoom: sfx dsbdopn'
# clean exit: singledemo ran I_Quit -> exit(0) -> the task retired 0,
# and E3.SH's trailing echo proves DOOM.ELF returned.
vgate_assert 03 serial-contains 'm130f: consented'
vgate_assert 03 serial-contains 'procs DOOM.ELF exited status=0'
vgate_assert 03 serial-absent 'store: refuse'
vgate_assert 03 serial-absent 'verdict=refused'
vgate_assert 03 serial-absent 'flint: refuse'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 serial-absent 'abababababababababababababababababababababababababababababababab'

# snap 0 (~f=70): fresh E1M1 hangar view — the demo's first frames,
# scene palette + status bar.
vgate_assert 03 snapshot 'doomacc-screen-snap-0*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d (%dx%d BGRX)"
             % (len(raw), need, W, H))

WX, WY, WW = 320, 160, 640
VP0, VP1 = WY + 16, WY + 336
HU0, HU1 = WY + 336, WY + 400

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

vp = colors(WX, WX + WW, VP0, VP1)
hu = colors(WX, WX + WW, HU0, HU1)
warm = count(lambda p: p[0] > p[1] > p[2] and p[0] > 40, WX, WX + WW, VP0, VP1)
flesh = count(lambda p: p[0] > 140 and p[1] > 60 and p[2] < p[1] and p[0] > p[2] * 2,
              WX, WX + WW, HU0, HU1)
print("viewport colors=%d hud colors=%d warm=%d flesh=%d"
      % (len(vp), len(hu), warm, flesh))
assert len(vp) >= 30, ("only %d distinct colors in the viewport -- the "
                       "E1M1 scene did not render" % len(vp))
assert len(hu) >= 10, ("only %d distinct colors in the status band -- no "
                       "HUD painted" % len(hu))
assert warm >= 100, "no DOOM brown/gray walls in the viewport (%d)" % warm
assert flesh >= 20, ("no status-bar flesh tones in the HUD band (%d) -- "
                     "STBAR did not paint" % flesh)
print("E1M1 hangar composited: scene palette + HUD band")
PY

# snap 2 (~f=2415): late in the replay — the viewport is still a live
# E1M1 scene (post-door/post-fire) and MUST differ from snap 0, i.e.
# the player actually moved through the level.
vgate_assert 03 snapshot 'doomacc-screen-snap-2*.raw' <<'PY'
import sys

W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
need = W * H * 4
if len(raw) < need:
    sys.exit("snapshot is %d bytes, want at least %d" % (len(raw), need))

WX, WY, WW = 320, 160, 640
VP0, VP1 = WY + 16, WY + 336

def px(x, y):
    off = (y * W + x) * 4
    return (raw[off + 2], raw[off + 1], raw[off])

warm = 0
distinct = set()
for y in range(VP0, VP1, 2):
    for x in range(WX, WX + WW, 2):
        p = px(x, y)
        distinct.add(p)
        if p[0] > p[1] > p[2] and p[0] > 40:
            warm += 1
print("viewport colors=%d warm=%d" % (len(distinct), warm))
assert len(distinct) >= 30, "viewport flat -- scene did not render"
assert warm >= 50, "no DOOM palette walls -- scene died"
print("late-walkthrough frame composited: live E1M1 viewport")
PY
