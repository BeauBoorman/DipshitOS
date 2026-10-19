# live-doom-sound.spec -- class-B gate (M130d, #2621, ADR 0058): DOOM's WAD
# PCM sound-effect lumps reach sys_audio. Sibling doom-engine builds DOOM.ELF;
# the engine's vl_sound module decodes DMX lumps, mixes channels, resamples to
# the negotiated tuple, and streams bounded periods through the slot-43 bit-63
# mixer ABI. Scripted input fires the weapon (ctrl-x); serial markers prove a
# decoded ds* lump rode real PCM bytes through the seat's counters. A second
# soundless run proves the named refusals (no device, no music synth).
#
# Nothing GPL lands in this repo or image: the setup hook builds DOOM.ELF in
# the sibling checkout ($DOOM_ENGINE_DIR or ../doom-engine), verifies the
# shareware doom1.wad sha256, and stages both into the RUN share.
vgate_name live-doom-sound "M130d: DOOM sfx -> sys_audio; music refused by name"
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

subprocess.run(["make", "-C", engine, "doom.elf", "check-elf"], check=True)
elf = os.path.join(engine, "build", "DOOM.ELF")
if not os.path.isfile(elf):
    sys.exit("build/DOOM.ELF missing after make")

WAD_SHA256 = "1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771"
wad = os.path.join(engine, "assets", "doom1.wad")
if not os.path.isfile(wad):
    sys.exit("assets/doom1.wad missing in %s" % engine)
if hashlib.sha256(open(wad, "rb").read()).hexdigest() != WAD_SHA256:
    sys.exit("doom1.wad sha256 mismatch -- not the pinned shareware 1.9 asset")

shutil.copy(elf, os.path.join(share, "DOOM.ELF"))
shutil.copy(wad, os.path.join(share, "doom1.wad"))
open(os.path.join(share, "SETTINGS.TXT"), "w", encoding="utf-8").write(
    "#v2\nwm=none\n")
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
echo rx-doomsnd-poke
EOF

vgate_file script-done.txt <<'EOF'
echo rx-doomsnd-done
EOF

# exec-order: assert-proven -- the --sound leg. --input-key 3 ('f', HID usage 0x09) posts a
# keyDown with no keyUp at f=140 — DOOM fires while the fire key is HELD,
# so a held 'f' refires the pistol for the rest of the run: deterministic
# dspistol lumps -> channel -> mixed period -> seat queue -> device. (A
# ctrl-x chord tap was observed to produce no attack — the tap's down/up
# pair can land inside one event-drain window, 2026-10-19. --input-key is
# a single flag, so the held 'w' from M130c is dropped here; the turn/use
# chords stay.)
# Poke/done scripts pace the console while the run continues.
vgate_run 01 -- \
    --sound \
    --screen '$RUN_DIR/doomsnd-screen' \
    --input-key 3 --input-key-after 'vldoom: f=140' \
    --input-chords 'left,space' --input-chords-after 'vldoom: f=210' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script-poke.txt' --script2-after 'vldoom: f=245' \
    --script3 '$RUN_DIR/script-done.txt' --script3-after 'vldoom: f=315' \
    --script-expect 'rx-doomsnd-done' --timeout 240

vgate_assert 01 output-contains 'SOUND: virtio-snd attached'
vgate_assert 01 serial-contains 'exec: loaded DOOM.ELF'
vgate_assert 01 serial-contains 'vldoom: level'
# the seat opened on the negotiated tuple
vgate_assert 01 serial-contains 'vldoom: snd fmt='
# a real WAD ds* lump decoded and bound to a channel
vgate_assert 01 serial-contains 'vldoom: sfx ds'
# the named music refusal (no synthesizer on this platform)
vgate_assert 01 serial-contains 'vldoom: music unsupported'
vgate_assert 01 serial-contains 'vldoom: key dn hid=0x09 doom=0xa3'
vgate_assert 01 serial-contains 'rx-doomsnd-done'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# The acceptance identity: after the fire chord, a pcm counter line reports
# submitted > 0 (periods accepted), nonzero > 0 (periods carrying mixed sfx),
# and completed > 0 (the kernel mixer actually played this seat's bytes).
vgate_assert 01 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace")
marks = re.findall(
    r"vldoom: pcm submitted=(\d+) nonzero=(\d+) completed=(\d+) "
    r"underruns=(\d+) refused=(\d+)", ser)
if not marks:
    sys.exit("ERROR: no 'vldoom: pcm' counter line in serial")
sub, nonz, comp, underr, refused = (int(g) for g in marks[-1])
print("last pcm counters: submitted=%d nonzero=%d completed=%d "
      "underruns=%d refused=%d" % (sub, nonz, comp, underr, refused))
if sub == 0:
    sys.exit("ERROR: seat accepted zero PCM bytes")
if nonz == 0:
    sys.exit("ERROR: every submitted period was silence -- no sfx mixed")
if comp == 0:
    sys.exit("ERROR: kernel mixer completed zero bytes from the seat")
sfx = [l for l in ser.splitlines() if "vldoom: sfx ds" in l]
print("sfx lines: %d (first: %s)" % (len(sfx), sfx[0] if sfx else "-"))
if not sfx:
    sys.exit("ERROR: no ds* lump was bound to a channel")
PY

# The soundless twin: no --sound device. DOOM still boots, reaches the level,
# and the module names its refusal instead of pretending to play.
vgate_run 02 -- \
    --screen '$RUN_DIR/doomsnd-screen-nodev' \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script-poke.txt' --script2-after 'vldoom: f=105' \
    --script3 '$RUN_DIR/script-done.txt' --script3-after 'vldoom: f=140' \
    --script-expect 'rx-doomsnd-done' --timeout 180

vgate_assert 02 serial-contains 'vldoom: level'
vgate_assert 02 serial-contains 'vldoom: snd nodev'
vgate_assert 02 serial-contains 'vldoom: music unsupported'
vgate_assert 02 serial-contains 'vldoom: f=140 t='
vgate_assert 02 serial-absent 'vldoom: snd fmt='
vgate_assert 02 serial-absent 'vldoom: sfx ds'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
