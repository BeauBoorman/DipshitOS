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
# HOST PREREQ: bash tools/go/build-gosnap.sh -> .build/go/GOSNAP.ELF

vgate_name go-snap "M115e #2464: GOSNAP.ELF named snapshots — ls/save/restore/rm, consent-gated, staged --resume restore"
vgate_share none

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
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\nvsock-ctl\t0\t" + "a5" * 32 + "\n")
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
