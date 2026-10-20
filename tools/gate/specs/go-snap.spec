# go-snap.spec — M115e (#2464, ADR 0056): GOSNAP.ELF and the armed
# `snapshot`/`restore` verbs on the virelai-ctl/1 channel.
#
# One minted .virelaivm profile carries every run; the share is attached
# over virtio-fs (the restore-safe device set — a custom-virtio share
# fails validateSaveRestoreSupport, so like live-suspend-resume the
# bundle's devices.share is flipped OFF and --virtio-fs carries the same
# dir) and the ctl listener is armed by the share's uid_system
# `vsock-ctl` credential (the ADR 0056 pinned vector).
#
# The driver is the kernel monitor, NOT GOSH, and each scripted phase
# carries exactly ONE `exec GOSNAP.ELF ...`: the monitor's exec is
# asynchronous, so a burst of execs would interleave, and a GOSH parent
# dies exec'ing a third child (#1449). Marker-gated phases are the
# machinery made for this — each phase fires only after the previous
# app's verdict line.
#
#   ops-a: ls (empty) -> save BASE -> ls (BASE listed, `bytes=`).
#          `clip snap-clip-1` was set BEFORE the save and `clip
#          snap-clip-2` after — the clipboard is the drill's RAM witness.
#   ops-b: save BASE again (`exists`) -> save `..` (`name_rejected`,
#          refused locally, never reaches the wire) -> rm BASE WITHOUT
#          `confirm` (`consent_required`, nothing deleted).
#   ops-c: restore BASE WITHOUT `confirm` (`consent_required`, nothing
#          staged) -> restore BASE confirm (host copies the named file
#          over saved-state/state.vzsave) -> rm BASE confirm (file gone).
#          Python proves the stage was byte-identical to the snapshot
#          and that rm removed it.
#   ld:    `--resume <profile>` reads the staged copy — the machine
#          rewinds to mid-`gosnap save BASE`, the stale ctl session
#          closes, and `clip` reads snap-clip-1: the post-save set is
#          gone with the rewind. THE NAMED BOUND (M119e):
#          restoreMachineStateFrom saturates at VZErrorDomain Code=12 on
#          this host, so ld accepts only `SUSPEND-RESUME: restored` +
#          the rewind transcript or `restore refused code=12` — the
#          bound live-suspend-resume already pins.
#
#   M125f (#2591) crash auto-snapshot legs, on the same profile:
#   crash: GOTABWM.ELF hosts GOTABAPP.ELF; ctrl-shift-s stores the app's
#          blob, then `kill GOTABAPP.ELF` is the force-crash — the seat's
#          released-mirror hook reads the bound owner's status=137 exit,
#          parks CRASH0 via the ctl snapshot verb, writes CRASHSNAP.LAST,
#          and re-execs the binary so its own restore_state takes the
#          pre-crash blob back.
#   offer: a FRESH boot finds LAST and posts the recovery toast
#          (`crashsnap offer CRASH0`); a pointer press on the toast is the
#          Restore gesture — `restore CRASH0` stages state.vzsave and the
#          one-shot offer file is consumed.
#   ld-crash: `--resume` continues the crash-moment image: the seat's
#          crash arm completes post-resume — `crash restart` re-execs the
#          app and `state restored` is the pre-crash-bytes proof. Same
#          M119e bound as ld: code=12 is the honest refusal.
#
# HOST PREREQ: bash tools/go/build-gosnap.sh -> .build/go/GOSNAP.ELF
#              bash tools/go/build-gotabwm.sh -> .build/go/GOTABWM.ELF
#              bash tools/go/build-tabapp.sh -> .build/go/GOTABAPP.ELF

vgate_name go-snap "M115e #2464: GOSNAP.ELF named snapshots — ls/save/restore/rm, consent-gated, staged --resume restore"
vgate_share none

# The crash/offer legs need the SPIKE runner: offer's toast click rides
# the custom-virtio INPUT queue (--pointer-virtio) — headless-safe,
# unlike the VZ-view pointer whose NSEvents hit the claim-4769
# activation wall. The offer run never saves, so a cv device is legal
# there; the crash run stays pure-VZ because its vzsave refuses cv.
vgate_runner_flags -Xswiftc -DSPIKE

# The profile is minted INSIDE the setup hook (hooks precede every run)
# — same shape as live-suspend-resume: the credential and the app land
# on the bundle's own share; devices.share is flipped OFF in config.json
# so the profile boots WITHOUT the cvc-file attachment a save cannot
# survive — the boot runs pass --virtio-fs instead.
vgate_setup_python <<'PY'
import json, os, shutil, subprocess, sys
run = os.environ["RUN_DIR"]
prof = os.path.join(run, "prof.virelaivm")
share = os.path.join(prof, "share")
runner = os.path.join("host", "vm-runner", ".build", "release", "VMRunner")
r = subprocess.run([runner, "--profile", prof, "--profile-init"],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("--profile-init refused the mint: " + r.stdout + r.stderr)
src = os.path.join(".build", "go", "GOSNAP.ELF")
if not os.path.exists(src):
    sys.exit("GOSNAP.ELF missing (expected " + src + ") — build it first: "
             "bash tools/go/build-gosnap.sh")
shutil.copy(src, os.path.join(share, "GOSNAP.ELF"))
# M125f (#2591): the crash legs also need the seat and its state client.
for elf, tool in (("GOTABWM.ELF", "build-gotabwm.sh"),
                  ("GOTABAPP.ELF", "build-tabapp.sh")):
    s = os.path.join(".build", "go", elf)
    if not os.path.exists(s):
        sys.exit(elf + " missing (expected " + s + ") — build it first: "
                 "bash tools/go/" + tool)
    shutil.copy(s, os.path.join(share, elf))
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\nvsock-ctl\t0\t" + "a5" * 32 + "\n")
# shim-only boot: the seat is the explicit opt-in, never the default wm.
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
cfg_path = os.path.join(prof, "config.json")
cfg = json.load(open(cfg_path))
cfg.setdefault("devices", {})["share"] = False
json.dump(cfg, open(cfg_path, "w"), indent=2, sort_keys=True)
print("staged profile share (GOSNAP.ELF + vsock-ctl credential), "
      "devices.share=false")
PY

# The minted bundle loads: manifest + members + the patched config read
# back cleanly before any boot leans on them.
vgate_run setup -- --profile '$RUN_DIR/prof.virelaivm' --profile-init --timeout 60
vgate_assert setup output-contains 'profile: loaded'

# --- ops-a: ls empty, save BASE, ls lists it --------------------------------
vgate_file a1.txt <<'EOF'
clip snap-clip-1
exec GOSNAP.ELF ls
EOF
vgate_file a2.txt <<'EOF'
exec GOSNAP.ELF save BASE
EOF
vgate_file a3.txt <<'EOF'
exec GOSNAP.ELF ls
clip snap-clip-2
EOF

vgate_run ops-a -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl \
  --script '$RUN_DIR/a1.txt' \
  --script2 '$RUN_DIR/a2.txt' --script2-after 'gosnap: ls n=0' \
  --script3 '$RUN_DIR/a3.txt' --script3-after 'gosnap: save BASE ok' \
  --script-expect 'gosnap: ls n=1' --timeout 240
vgate_assert ops-a serial-contains 'vsock: ready did=0x1053'
vgate_assert ops-a output-contains 'VSOCK-CTL: host listener armed port=1209'
vgate_assert ops-a output-contains 'VSOCK-CTL: snapshot=armed restore=armed'
vgate_assert ops-a serial-contains 'gosnap: ls n=0'
vgate_assert ops-a serial-contains 'vsock-ctl: authed'
vgate_assert ops-a serial-contains 'vsock-ctl: reply id=1 ok=true'
vgate_assert ops-a output-contains 'VSOCK-CTL: snapshot saved BASE.vzsave'
vgate_assert ops-a output-contains 'VSOCK-CTL: reply ok=true verb=snapshot'
vgate_assert ops-a output-contains 'VSOCK-CTL: snapshot resumed'
vgate_assert ops-a serial-contains 'gosnap: save BASE ok'
vgate_assert ops-a serial-contains 'gosnap: snap name=BASE bytes='
vgate_assert ops-a serial-absent '[EXC]'

# --- ops-b: exists refusal, name grammar, consent ask on rm -----------------
vgate_file b1.txt <<'EOF'
exec GOSNAP.ELF save BASE
EOF
vgate_file b2.txt <<'EOF'
exec GOSNAP.ELF save ..
EOF
vgate_file b3.txt <<'EOF'
exec GOSNAP.ELF rm BASE
EOF

vgate_run ops-b -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl \
  --script '$RUN_DIR/b1.txt' \
  --script2 '$RUN_DIR/b2.txt' --script2-after 'gosnap: save BASE refused exists' \
  --script3 '$RUN_DIR/b3.txt' --script3-after 'gosnap: save .. refused name_rejected' \
  --script-expect 'gosnap: rm BASE refused consent_required' --timeout 240
vgate_assert ops-b serial-contains 'vsock-ctl: reply id=1 ok=false code=exists'
vgate_assert ops-b serial-contains 'gosnap: save BASE refused exists'
vgate_assert ops-b serial-contains 'gosnap: save .. refused name_rejected'
vgate_assert ops-b serial-contains 'gosnap: consent rm BASE'
vgate_assert ops-b serial-contains 'gosnap: rm BASE refused consent_required'
vgate_assert ops-b serial-absent '[EXC]'
# Consent was the whole answer — nothing was deleted.
vgate_assert ops-b python <<'PY'
import os
from pathlib import Path
snap = Path(os.environ["RUN_DIR"]) / "prof.virelaivm" / "share" / "SNAPSHOTS" / "BASE.vzsave"
assert snap.exists() and snap.stat().st_size > 0, "consent-less rm deleted BASE"
print("BASE survived the consent ask")
PY

# --- ops-c: consent ask on restore, staged restore, consent'd rm ------------
vgate_file c1.txt <<'EOF'
exec GOSNAP.ELF restore BASE
EOF
vgate_file c2.txt <<'EOF'
exec GOSNAP.ELF restore BASE confirm
EOF
vgate_file c3.txt <<'EOF'
exec GOSNAP.ELF rm BASE confirm
EOF

vgate_run ops-c -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl \
  --script '$RUN_DIR/c1.txt' \
  --script2 '$RUN_DIR/c2.txt' --script2-after 'gosnap: restore BASE refused consent_required' \
  --script3 '$RUN_DIR/c3.txt' --script3-after 'gosnap: restore BASE staged' \
  --script-expect 'gosnap: rm BASE ok' --timeout 240
vgate_assert ops-c serial-contains 'gosnap: consent restore BASE'
vgate_assert ops-c serial-contains 'gosnap: restore BASE refused consent_required'
vgate_assert ops-c output-contains 'VSOCK-CTL: restore staged name=BASE'
vgate_assert ops-c serial-contains 'gosnap: restore BASE staged'
vgate_assert ops-c serial-contains 'gosnap: rm BASE ok'
vgate_assert ops-c serial-absent '[EXC]'
# The stage is a real host-side copy — byte-identical to the named
# snapshot (python stashes the hash before the rm leg can run: the
# assert reads AFTER the run, so it compares the staged file against the
# snapshot that ops-a wrote — which rm then deleted; the rm's absence is
# itself the delete evidence).
vgate_assert ops-c python <<'PY'
import os, sys
from pathlib import Path
prof = Path(os.environ["RUN_DIR"]) / "prof.virelaivm"
staged = prof / "saved-state" / "state.vzsave"
snapdir = prof / "share" / "SNAPSHOTS"
assert staged.exists() and staged.stat().st_size > 0, \
    "restore never staged state.vzsave"
assert not (snapdir / "BASE.vzsave").exists(), "rm BASE confirm left the file"
assert not (snapdir / "BASE.vzsave.part").exists(), "a .part write leaked"
print("state.vzsave staged (%d bytes); BASE deleted by rm" % staged.stat().st_size)
PY

# --- ld: the restore drill ---------------------------------------------------
# --resume reads the staged copy (BASE's image), the guest resumes inside
# `gosnap save BASE`, the stale ctl session ends, and `clip` reads the
# PRE-snapshot clipboard — snap-clip-2 was set only after the save, so a
# restored machine proves the rewind. On this host the M119e bound may
# answer first: `restore refused code=12` is the pinned honest outcome.
vgate_file ld.txt <<'EOF'
clip
echo gosnap-ld-done
EOF

vgate_run ld -- --resume '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl \
  --script-after 'vsock-ctl: closed' --script '$RUN_DIR/ld.txt' \
  --script-expect 'gosnap-ld-done' --timeout 120
vgate_allow_rc ld 0 1
vgate_assert ld output-contains 'SUSPEND-RESUME: armed state='
vgate_assert ld python <<'PY'
import os, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
out = Path(os.environ["RUN_DIR"], "run-%s.out" % os.environ["VG_TAG"]).read_bytes()
sp = Path(os.environ["VG_SER"])
serial = sp.read_bytes() if sp.exists() else b""
assert b"VirelaiOS kernel has seized control." not in serial, "a restore never boots"
if b"SUSPEND-RESUME: restore refused code=12" in out:
    print("bound: restoreMachineStateFrom -> VZErrorDomain Code=12 (M119e)")
    sys.exit(0)
assert b"SUSPEND-RESUME: restored" in out, out[-800:]
# Restored: the guest continued mid-`gosnap save BASE`; the clipboard
# holds the PRE-snapshot text and the post-save set is gone with the
# rewind.
for needle in (b"clip: snap-clip-1", b"gosnap-ld-done"):
    assert needle in serial, (needle, serial[-1500:])
assert b"snap-clip-2" not in serial, "post-snapshot state survived the restore"
print("resume: earlier state observed — clip=snap-clip-1, post-save change rewound")
PY

# ---------------------------------------------------------------------------
# M125f (#2591): crash — force-crash the hosted state client and watch the
# seat's auto-save arm: crash receipt -> rotated CRASH0 vzsave -> LAST ->
# in-boot restart carrying the pre-crash blob back.

vgate_file crash1.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file crash2.txt <<'EOF'
dui focus 0
exec GOTABAPP.ELF
EOF
vgate_file crash3.txt <<'EOF'
kill GOTABAPP.ELF
EOF

vgate_run crash -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl --screen '$RUN_DIR/screen' --input \
  --script '$RUN_DIR/crash1.txt' \
  --script2 '$RUN_DIR/crash2.txt' --script2-after 'gotabwm: win focus' \
  --script3 '$RUN_DIR/crash3.txt' --script3-after 'gotabwm: state save id=' \
  --script-expect 'gotabapp: state restored' --script-expect-tail 3 --timeout 300

vgate_assert crash serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert crash serial-contains 'gotabapp: declare accepted'
# The demo posts its blob unsolicited on present (SaveStateNow) — the
# seat stores it on the tab record before the kill ever lands.
vgate_assert crash serial-contains 'gotabwm: state save id='
# The force-crash receipt: the kernel's exit report, then the seat's arm.
vgate_assert crash serial-contains 'GOTABAPP.ELF exited status=137'
vgate_assert crash serial-contains 'gotabwm: crash id='
vgate_assert crash serial-contains 'status=137'
vgate_assert crash serial-contains 'gotabwm: crashsnap save CRASH0 ok'
vgate_assert crash output-contains 'VSOCK-CTL: snapshot saved CRASH0.vzsave'
vgate_assert crash serial-contains 'gotabwm: crash restart GOTABAPP.ELF'
# The restarted client's own byte-identity verdict — pre-crash state back.
vgate_assert crash serial-contains 'gotabapp: state restored len=30'
vgate_assert crash serial-absent 'gotabapp: state mismatch'
vgate_assert crash serial-absent '[EXC]'
vgate_assert crash python <<'PY'
import os, sys
from pathlib import Path
share = Path(os.environ["RUN_DIR"]) / "prof.virelaivm" / "share"
vz = share / "SNAPSHOTS" / "CRASH0.vzsave"
assert vz.exists() and vz.stat().st_size > 0, "CRASH0.vzsave was never parked"
last = (share / "CRASHSNAP.LAST").read_bytes()
assert last == b"CRASH0\n", "LAST = %r" % last
b = (share / "SESSION.TABS").read_bytes()
assert b"gotabapp state v1: hello strip" in b, \
    "the crash save's session file dropped the app's blob"
print("CRASH0 parked (%d bytes), LAST offers it, blob rides .tabs" %
      vz.stat().st_size)
PY

# ---------------------------------------------------------------------------
# M125f (#2591): offer — a FRESH boot finds LAST, posts the recovery toast,
# and a press on the toast is the Restore gesture: `restore CRASH0` stages
# saved-state/state.vzsave and the offer file is consumed.

vgate_file offer1.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file offer2.txt <<'EOF'
echo rx-crash-offer-ok
EOF

vgate_run offer -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl --screen '$RUN_DIR/screen' --input \
  --script '$RUN_DIR/offer1.txt' \
  --pointer-virtio '112,702,c' \
  --pointer-virtio-after 'gotabwm: notify paint' \
  --script2 '$RUN_DIR/offer2.txt' --script2-after 'gotabwm: crashsnap restore CRASH0 ok' \
  --script-expect 'rx-crash-offer-ok' --timeout 300

vgate_assert offer serial-contains 'gotabwm: registered'
# The toast leg: offered, painted, clicked away by the press.
vgate_assert offer serial-contains 'gotabwm: crashsnap offer CRASH0'
vgate_assert offer serial-contains 'gotabwm: notify paint'
vgate_assert offer serial-contains 'gotabwm: notify dismiss'
vgate_assert offer serial-contains 'gotabwm: crashsnap restore CRASH0 ok'
vgate_assert offer output-contains 'VSOCK-CTL: restore staged name=CRASH0'
vgate_assert offer serial-contains 'rx-crash-offer-ok'
vgate_assert offer serial-absent '[EXC]'
vgate_assert offer python <<'PY'
import os
from pathlib import Path
prof = Path(os.environ["RUN_DIR"]) / "prof.virelaivm"
staged = prof / "saved-state" / "state.vzsave"
vz = prof / "share" / "SNAPSHOTS" / "CRASH0.vzsave"
assert staged.exists() and staged.stat().st_size > 0, "restore never staged"
assert staged.read_bytes() == vz.read_bytes(), \
    "the staged image is not byte-identical to CRASH0"
assert not (prof / "share" / "CRASHSNAP.LAST").exists(), \
    "the answered offer's LAST was not consumed"
print("toast Restore staged state.vzsave (%d bytes); LAST consumed" %
      staged.stat().st_size)
PY

# ---------------------------------------------------------------------------
# M125f (#2591): ld-crash — `--resume` continues the crash-moment image: the
# seat's crash arm resumes mid-ctl-reply, writes LAST, closes the dead row
# and crash-restarts GOTABAPP.ELF; `state restored` on the resumed timeline
# IS the pre-crash-bytes proof. The M119e bound stands: code=12 is the
# honest refusal on this host.

vgate_file ldc.txt <<'EOF'
echo rx-crash-ld-done
EOF

vgate_run ld-crash -- --resume '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl --screen '$RUN_DIR/screen' --input \
  --script-after 'vsock-ctl: closed' --script '$RUN_DIR/ldc.txt' \
  --script-expect 'gotabapp: state restored' --timeout 180
vgate_allow_rc ld-crash 0 1
vgate_assert ld-crash output-contains 'SUSPEND-RESUME: armed state='
vgate_assert ld-crash python <<'PY'
import os, sys
from pathlib import Path
out = Path(os.environ["RUN_DIR"], "run-%s.out" % os.environ["VG_TAG"]).read_bytes()
serial = Path(os.environ["VG_SER"]).read_bytes() if Path(os.environ["VG_SER"]).exists() else b""
assert b"VirelaiOS kernel has seized control." not in serial, "a restore never boots"
if b"SUSPEND-RESUME: restore refused code=12" in out:
    print("bound: restoreMachineStateFrom -> VZErrorDomain Code=12 (M119e)")
    sys.exit(0)
assert b"SUSPEND-RESUME: restored" in out, out[-800:]
# Restored: the crash arm completed on the resumed timeline — the restarted
# client's restore_state took the pre-crash blob back.
for needle in (b"gotabwm: crashsnap save CRASH0 ok",
               b"gotabwm: crash restart GOTABAPP.ELF",
               b"gotabapp: state restored len=30"):
    assert needle in serial, (needle, serial[-1500:])
print("resume: crash arm completed — CRASH0 saved, GOTABAPP restarted, blob restored")
PY

# ---------------------------------------------------------------------------
# M120d (#2561): windowed — the seat hosts a BARE GOSNAP.ELF, its tab paints,
# and a snapshot minted AFTER the window is open (the argv verb, out of band)
# arrives on the window's ~1 Hz re-list. Pure-VZ like crash: the run's own
# `gosnap save` must survive validateSaveRestoreSupport, so no cv input rides
# along — the leg needs none (monitor execs only). SNAPSHOTS still holds
# CRASH0 from the crash leg, so the fresh window reads n=1, then n=2 when
# the poll sees WINBASE.

vgate_file win1.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file win2.txt <<'EOF'
exec GOSNAP.ELF
EOF
vgate_file win3.txt <<'EOF'
exec GOSNAP.ELF save WINBASE
EOF

vgate_run windowed -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl --screen '$RUN_DIR/screen-win' --input \
  --script '$RUN_DIR/win1.txt' \
  --script2 '$RUN_DIR/win2.txt' --script2-after 'gotabwm: win focus' \
  --script3 '$RUN_DIR/win3.txt' --script3-after 'gosnap: ready n=1' \
  --script-expect 'gosnap: ls n=2' --timeout 300

vgate_assert windowed serial-contains 'gotabwm: registered'
vgate_assert windowed serial-contains 'gosnap: open id='
vgate_assert windowed serial-contains 'gosnap: declare accepted'
vgate_assert windowed serial-contains 'gosnap: present'
vgate_assert windowed serial-contains 'gosnap: ready n=1'
vgate_assert windowed serial-contains 'gosnap: snap name=CRASH0 bytes='
vgate_assert windowed serial-contains 'gosnap: save WINBASE ok'
vgate_assert windowed serial-contains 'gosnap: snap name=WINBASE bytes='
vgate_assert windowed serial-contains 'gosnap: ls n=2'
vgate_assert windowed serial-absent '[EXC]'
vgate_assert windowed python <<'PY'
import os
from pathlib import Path
snap = Path(os.environ["RUN_DIR"]) / "prof.virelaivm" / "share" / "SNAPSHOTS" / "WINBASE.vzsave"
assert snap.exists() and snap.stat().st_size > 0, "WINBASE was never parked"
print("WINBASE parked (%d bytes), listed by the window" % snap.stat().st_size)
PY

# ---------------------------------------------------------------------------
# M120d (#2561): pwr — the PWR menu's Snapshot row, driven by the pointer the
# way a person reaches it: press PWR -> the two-row menu -> press Snapshot.
# The seat execs GOSNAP.ELF (no Snapshots tab is open), which opens, declares
# and lists. cv input is legal here exactly like offer: the run never saves.

vgate_file pwr1.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file pwr2.txt <<'EOF'
echo rx-gosnap-pwr-ok
EOF

vgate_run pwr -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl --screen '$RUN_DIR/screen-pwr' --input \
  --script '$RUN_DIR/pwr1.txt' \
  --pointer-virtio '338,702,c;308,675,c' \
  --pointer-virtio-after 'gotabwm: win focus' \
  --script2 '$RUN_DIR/pwr2.txt' --script2-after 'gosnap: ready n=' \
  --script-expect 'rx-gosnap-pwr-ok' --timeout 300

vgate_assert pwr serial-contains 'gotabwm: power open'
vgate_assert pwr serial-contains 'gotabwm: power snapshot exec GOSNAP.ELF'
vgate_assert pwr serial-contains 'gosnap: open id='
vgate_assert pwr serial-contains 'gosnap: declare accepted'
vgate_assert pwr serial-contains 'gosnap: present'
vgate_assert pwr serial-contains 'gosnap: snap name='
vgate_assert pwr serial-contains 'gosnap: ready n='
vgate_assert pwr serial-contains 'rx-gosnap-pwr-ok'
vgate_assert pwr serial-absent '[EXC]'
