# live-host-clipboard.spec -- M108b (#2325, ADR 0051) class-B: the
# bidirectional clipboard lane over signed VHI1 share files.
#
# Run 01 is the full journey: the seat adopts the runner's ARMED, a
# marker-timed host pasteboard write lands in the guest clipboard (seat
# applies CLIP_IN through slot 38, the tray badge flips host-marked), a
# monitor `clip` write crosses the other way (seat emits CLIP_OUT, runner
# mirrors to the NAMED pasteboard -- never .general), and two planted
# records prove the MAC/epoch refusals live. Run 02 is the flags-off
# posture: the same credentialed share, no --host-clipboard -- byte-silent
# both directions, no HOSTINT/ created.
#
# The credential rides the share's SECRETS.TXT, bound to GOTABWM.ELF (the
# ADR 0024 D8 app binding: uid_system-owned in OWNERS.TXT, 644). The seat
# is exec'd explicitly (wm=none) so the choreography times off its markers.
#
# HOST PREREQ:
#   bash tools/go/build-gotabwm.sh  -> .build/go/GOTABWM.ELF

vgate_name live-host-clipboard "M108b #2325: bidirectional clipboard lane over signed VHI1 share files (ADR 0051)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script-seat.txt <<'EOF'
exec GOTABWM.ELF
EOF

vgate_file script-clip.txt <<'EOF'
clip gate-guest-copy-77
EOF

vgate_file script-paste.txt <<'EOF'
clip
EOF

vgate_setup_python <<'PY'
import hashlib, hmac, os, shutil, struct, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.isfile(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
# wm=none: the seat is exec'd on script, like go-agentd.spec.
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
# The lane credential: the row the seat reads via sys_secret_get (image
# binding needs the uid_system OWNERS row) and the runner reads as a host
# file. Value bytes ARE the HMAC key verbatim.
KEY = "clipkey0" * 8  # 64 bytes, ASCII
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n" + "host-int\t1000\t" + KEY + "\tGOTABWM.ELF\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nGOTABWM.ELF\t644\t0\t-\n")
# Two planted lane records exercise the refusals live: (a) a correctly
# signed CLIP_IN under a foreign epoch -> stale_epoch; (b) a forged
# CLIP_IN under a wrong key -> bad_mac. Both must be deleted, never
# applied.
def rec(tag, flags, seq, epoch, payload, key):
    hdr = b"VHI1" + bytes([tag, flags, 0, 0]) + struct.pack(
        "<IIH", seq, epoch, len(payload))
    body = hdr + payload
    return body + hmac.new(key.encode(), body, hashlib.sha256).digest()
os.makedirs(os.path.join(share, "HOSTINT"), exist_ok=True)
open(os.path.join(share, "HOSTINT", "CLIPIN-00000077"), "wb").write(
    rec(2, 0, 0x77, 999, b"stale-epoch-plant", KEY))
open(os.path.join(share, "HOSTINT", "CLIPIN-00000088"), "wb").write(
    rec(2, 0, 0x88, 1, b"forged-plant", "wrongkey" * 8))
open(os.path.join(run, "key-sentinel.txt"), "w").write(KEY + "\n")
print("staged hostint share (GOTABWM + host-int credential + 2 refusal plants)")
PY

# ---- 01: both directions + refusal proofs, one boot -----------------------------
vgate_run 01 -- \
    --script '$RUN_DIR/script-seat.txt' \
    --script2 '$RUN_DIR/script-clip.txt' --script2-after 'gotabwm: hostint armed' \
    --script3 '$RUN_DIR/script-paste.txt' --script3-after 'gotabwm: hostint clip-in seq=1' \
    --host-clipboard --host-pasteboard 'virelai-gate-clip' \
    --host-clip-in 'gate-host-copy-88' --host-clip-in-after 'gotabwm: hostint armed' \
    --script-expect 'clip: gate-host-copy-88' --script-expect-tail 6 --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 01 serial-contains 'gotabwm: registered'
# The lane armed: seat adopted the runner's epoch and lane mask.
vgate_assert 01 output-contains 'host-int: armed lanes=clip epoch='
vgate_assert 01 serial-contains 'gotabwm: hostint armed epoch='
vgate_assert 01 serial-contains 'lanes=clip'
# The planted refusals: foreign-epoch signed record and the forgery.
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=clip reason=stale_epoch'
vgate_assert 01 serial-contains 'gotabwm: hostint refuse lane=clip reason=bad_mac'
vgate_assert 01 serial-absent 'stale-epoch-plant'
vgate_assert 01 serial-absent 'forged-plant'
# h->g: the inject fired on the armed marker, the seat applied CLIP_IN
# through slot 38, and the badge flipped host-marked. `clip` reads it back.
vgate_assert 01 output-contains 'host-clip: inject len=17'
vgate_assert 01 output-contains 'host-clip: in seq=1 sha256='
vgate_assert 01 output-contains 'truncated=0'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-in seq=1 len=17 truncated=0'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-ind host'
vgate_assert 01 serial-contains 'clip: gate-host-copy-88'
# g->h: the monitor `clip` write was observed on the seat's slot-39 poll,
# emitted as CLIP_OUT, and mirrored to the named pasteboard.
vgate_assert 01 serial-contains 'clip: stored 18 bytes'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-out seq=1 len=18'
vgate_assert 01 serial-contains 'gotabwm: hostint clip-ind local'
vgate_assert 01 output-contains 'host-clip: out seq=1 sha256='
vgate_assert 01 output-contains 'len=18'
vgate_assert 01 serial-absent '[EXC] parking:'
# The credential never reaches serial or runner stdout.
vgate_assert 01 serial-absent 'clipkey0clipkey0'
vgate_assert 01 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-01.out"), errors="replace").read()
key = open(os.path.join(run, "key-sentinel.txt")).read().strip()
if key in out:
    sys.exit("FAIL: the lane key reached runner stdout")
if "gate-host-copy-88" in out.split("host-clip: inject")[0] if "host-clip: inject" in out else False:
    sys.exit("FAIL: payload text reached stdout before the inject line")
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
names = sorted(os.listdir(os.path.join(share, "HOSTINT")))
left = [n for n in names if not n.endswith("~")]
if left:
    sys.exit("FAIL: unconsumed lane files left in HOSTINT: %r" % left)
print("run-01 lane hygiene ok")
PY

# ---- 02: flags-off is byte-silent ------------------------------------------------
# Same credential+share posture, no lane flag: the runner never creates
# HOSTINT/, never writes a record, never reads a pasteboard; the seat's
# once-per-tick listing sees a directory that never exists -- one cheap
# ENOENT per tick, zero lane markers either end. (The planted CLIPIN files
# from run 01's setup are staged into THIS share too by vgate_setup_python
# -- they sit unread in a runner-side dir the share never has, since the
# runner owns HOSTINT creation; the seat's ListDirAt of /HOSTINT answers
# ENOENT because the host folder itself was never created here.)
vgate_run 02 -- \
    --cvc-file '$RUN_DIR/off-share' \
    --script '$RUN_DIR/script-seat.txt' \
    --script-expect 'gotabwm: mode live' --script-expect-tail 10 --timeout 180

vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'gotabwm: mode live'
vgate_assert 02 serial-absent 'gotabwm: hostint'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
out = open(os.path.join(run, "run-02.out"), errors="replace").read()
for needle in ("host-int:", "host-clip:"):
    if needle in out:
        sys.exit("FAIL: flags-off run printed lane traffic: " + needle)
share = os.path.join(run, "off-share")
if os.path.isdir(os.path.join(share, "HOSTINT")):
    sys.exit("FAIL: flags-off run created HOSTINT/")
print("run-02 flags-off silence ok")
PY
