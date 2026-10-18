# live-persistence.spec — M115g (#2466): the M115 acceptance journey. One
# minted .virelaivm profile carries the whole arc K=3: a profile'd session
# snapshots itself, suspends itself, resumes, stages a signed OS update,
# applies it, rolls it back — every leg on the SAME bundle. This is the
# receipt M91's persistence exception never had ("the machine keeps
# itself", index #2448).
#
# Per iteration k (1..3), five runs on $RUN_DIR/prof.virelaivm:
#   j<k>  — virtio-fs share + vsock ctl. The monitor writes byte-fixtures
#           to BOTH surfaces (/host share + journaled /disk VLFS), loads
#           the clipboard, then `gosnap save J-k` parks a named snapshot
#           on share/SNAPSHOTS/ (pause, save, reply-while-frozen, resume)
#           and GOSH's `suspend` builtin quiesces (VLFS fsync, settings,
#           SUSPEND.MARK seq=k) and asks the host to save — the machine
#           freezes mid-syscall, state lands in saved-state/state.vzsave,
#           the host stops. The snapshot leg rides INSIDE this run: a
#           suspended machine has already stopped (nothing left to ask),
#           and on a Code=12 host a post-resume guest leg never runs —
#           the only honest place to park a checkpoint is while the
#           machine is live.
#   r<k>  — `--resume` restores the saved machine; GOSH reads its
#           suspend reply, $JRN survives, the clipboard and both fixture
#           surfaces read back byte-identical.
#   st<k> — a fresh profile boot stages the signed update: `sysinfo`
#           shows version=dev, GOUPD.ELF writes UPDATE/ to the share.
#   a<k>  — `--apply-update` verifies Ed25519 + manifest, swaps
#           base.img (.prev retained), discards the stale overlay, boots
#           the NEW kernel: sysinfo version=m115g-b.
#   rb<k> — `--rollback-update` swaps .prev back: sysinfo version=dev.
#
# The transport split is the M115 thesis made mechanical: the save legs
# ride --virtio-fs because a custom-virtio share cannot be saved
# (validateSaveRestoreSupport refuses it — M115a); the update legs ride
# --cvc-file because OWNERS.TXT only loads at the queue-5 arming point,
# and GOUPD's `os-update` signing row is app-bound (M97g) — on a
# virtio-fs-only boot the bound credential is unservable by design.
#
# THE NAMED BOUND (M119e): `restoreMachineStateFrom` saturates at
# VZErrorDomain Code=12 on some hosts — the bound live-vz-restore,
# live-vsock-restore, live-suspend-resume and go-snap all pin. Every r<k>
# accepts ONLY the two honest shapes: `SUSPEND-RESUME: restored` + the
# full state transcript, or `restore refused code=12`. A silent boot, any
# other error, or a missing marker fails. Save legs, staging, apply and
# rollback are unaffected by the bound — they run for real everywhere.
#
# HOST PREREQUISITES:
#   bash tools/go/build-gosh.sh    -> .build/go/GOSH.ELF   (ensure-guest-elf)
#   bash tools/go/build-gosnap.sh  -> .build/go/GOSNAP.ELF (hook check)
#   bash tools/go/build-goupd.sh   -> .build/go/GOUPD.ELF  (ensure-guest-elf)
#   zig build                      -> zig-out/bin/* + artifacts/disk.img
#                                   (the "old" payload, gate preamble)

vgate_name live-persistence "M115g #2466: the machine keeps itself — snapshot -> suspend -> resume -> stage -> apply -> rollback, K=3 on one .virelaivm profile; M119e Code=12 bound"
vgate_share none
vgate_runner_flags -Xswiftc -DSPIKE

# The profile is minted INSIDE the setup hook — same shape as
# live-suspend-resume: credentials + all three guest apps land on the
# bundle's own share, devices.share is flipped OFF in config.json so no
# transport auto-arms, and each leg passes its channel by flag —
# --virtio-fs on the save legs, --cvc-file on the update legs (see the
# header note). One share, one SECRETS.TXT carrying both rows: `vsock-ctl`
# (uid_system, app-unbound — the ctl channel credential) and `os-update`
# (slot-70 seed bound to GOUPD.ELF — the update signing key); OWNERS.TXT
# makes GOUPD.ELF uid_system-owned so the bound row is served to it.
# The bundle pins the update trust root itself via config.updatePubkey —
# no --update-key flag anywhere in the journey.
vgate_setup_python <<'PY'
import hashlib, json, os, shutil, subprocess, sys

run = os.environ["RUN_DIR"]
repo = os.getcwd()
runner = os.path.join("host", "vm-runner", ".build", "release", "VMRunner")

# The fleet's pinned Ed25519 test key (RFC 8032 TEST 1 — the same seed
# live-os-update stages as the `os-update` row bound to GOUPD.ELF).
SEED = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
PUB  = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
UPDATE_VERSION = "m115g-b"

def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

# --- guest ELFs: fail closed before anything else touches the profile ------
for app, chk in (("GOSH",   ["bash", "tools/go/ensure-guest-elf.sh", "check", "GOSH"]),
                 ("GOSNAP", ["bash", "tools/go/build-gosnap.sh", "check"]),
                 ("GOUPD",  ["bash", "tools/go/ensure-guest-elf.sh", "check", "GOUPD"])):
    r = subprocess.run(chk, capture_output=True, text=True, cwd=repo)
    if r.returncode != 0:
        sys.exit("%s.ELF freshness refused: %s%s" % (app, r.stdout, r.stderr))

# --- the "next" payload: a real second kernel pair -------------------------
upd_prefix = os.path.join(run, "upd-zig")
r = subprocess.run(["zig", "build", "-Dos-version=" + UPDATE_VERSION,
                    "--prefix", upd_prefix],
                   capture_output=True, text=True, cwd=repo)
if r.returncode != 0:
    sys.exit("update payload build failed: " + r.stdout + r.stderr)
new_k = os.path.join(upd_prefix, "bin", "KERNEL.BIN")
new_e = os.path.join(upd_prefix, "bin", "BOOTAA64.EFI")
for p in (new_k, new_e):
    if not os.path.exists(p):
        sys.exit("payload build produced no " + p)
print("payload: KERNEL.BIN sha256=" + sha(new_k)[:16] +
      " BOOTAA64.EFI sha256=" + sha(new_e)[:16])

# --- the profile + its updatable private base -------------------------------
prof = os.path.join(run, "prof.virelaivm")
r = subprocess.run([runner, "--profile", prof, "--profile-init"],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("--profile-init refused the mint: " + r.stdout + r.stderr)
base = os.path.join(run, "base.img")
shutil.copy(os.path.join("artifacts", "disk.img"), base)
cfg_path = os.path.join(prof, "config.json")
cfg = json.load(open(cfg_path))
cfg["baseImage"] = base            # flag wins anyway; keeps bundle coherent
cfg["updatePubkey"] = PUB          # the bundle pins the update key
cfg.setdefault("devices", {})["share"] = False  # cvc cannot be saved
json.dump(cfg, open(cfg_path, "w"), indent=2, sort_keys=True)
print("profile minted; base.img is a private copy of artifacts/disk.img")

# --- share seeding ----------------------------------------------------------
share = os.path.join(prof, "share")
for app in ("GOSH", "GOSNAP", "GOUPD"):
    src = os.path.join(".build", "go", app + ".ELF")
    if not os.path.exists(src):
        sys.exit(app + ".ELF missing (expected " + src + ")")
    shutil.copy(src, os.path.join(share, app + ".ELF"))
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\n"
    "vsock-ctl\t0\t" + "a5" * 32 + "\n"
    "os-update\t1000\t" + SEED + "\tGOUPD.ELF\n")
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nGOUPD.ELF\t644\t0\t-\n")
nxt = os.path.join(share, "NEXT")
os.makedirs(nxt)
shutil.copy(new_k, os.path.join(nxt, "KERNEL.BIN"))
shutil.copy(new_e, os.path.join(nxt, "BOOTAA64.EFI"))
open(os.path.join(nxt, "VERSION.TXT"), "w").write(UPDATE_VERSION + "\n")

# A fresh bundle's vlfs.img is unformatted — format it with the same
# mkfs.vlfs the other VLFS gates drive (64 MiB default volume).
subprocess.check_call(["go", "-C", "tools/go/vlfs", "build",
                       "-o", os.path.join(run, "mkfs.vlfs"), "."], cwd=repo)
r = subprocess.run([os.path.join(run, "mkfs.vlfs"),
                    os.path.join(prof, "vlfs.img")],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("mkfs.vlfs refused the profile data disk: " + r.stdout + r.stderr)

for i in (1, 2, 3):
    # The GOSH exec phase (script2, fired after the snapshot verdict) is
    # identical every iteration; the suspend input and the post-restore
    # probe are per-iteration ($JRN k, marker k, resumed-k k).
    open(os.path.join(run, "gosh-sv%d.bin" % i), "wb").write(
        ("export JRN=1%d\r" % i
         + "echo pre-n=$JRN\r"
         + "suspend\r").encode())
    open(os.path.join(run, "gosh-ld%d.bin" % i), "wb").write(
        ("echo post-n=$JRN\r"
         + "monitor\r"
         + "clip\r"
         + "vf cat /disk/JP-DISK.TXT\r"
         + "vf cat JP-HOST.TXT\r"
         + "echo resumed-k%d\r" % i).encode())
print("staged share: GOSH+GOSNAP+GOUPD, SECRETS.TXT (vsock-ctl + "
      "os-update->GOUPD.ELF), OWNERS.TXT, NEXT/ payload; vlfs.img "
      "formatted; 3x sv/ld input pairs")
PY

# The minted bundle loads: manifest + members + the patched config read
# back cleanly before any boot leans on them.
vgate_run setup -- --profile '$RUN_DIR/prof.virelaivm' --profile-init --timeout 60
vgate_assert setup output-contains 'profile: loaded'

# --- Iteration 1 -------------------------------------------------------------
vgate_file script-j1.txt <<'EOF'
clip jp-clip-1
write JP-HOST.TXT host-bytes-j1-0123456789abcdef
write /disk/JP-DISK.TXT disk-bytes-j1-0123456789abcdef
vf cat /disk/JP-DISK.TXT
vf cat JP-HOST.TXT
exec GOSNAP.ELF save J-1
EOF

vgate_file gosh-exec.txt <<'EOF'
exec GOSH.ELF serial
EOF

vgate_run j1 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --vsock --vsock-ctl \
  --script '$RUN_DIR/script-j1.txt' \
  --script2 '$RUN_DIR/gosh-exec.txt' --script2-after 'gosnap: save J-1 ok' \
  --script3 '$RUN_DIR/gosh-sv1.bin' --script3-after 'gosh: attached' \
  --timeout 300
vgate_assert j1 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert j1 serial-contains 'vsock: ready did=0x1053'
vgate_assert j1 output-contains 'VSOCK-CTL: host listener armed port=1209 suspend=armed'
vgate_assert j1 output-contains 'VSOCK-CTL: snapshot=armed restore=armed'
vgate_assert j1 serial-contains 'vsock-ctl: authed'
vgate_assert j1 serial-count 'vsock-ctl: authed' 2
vgate_assert j1 output-contains 'VSOCK-CTL: snapshot saved J-1.vzsave'
vgate_assert j1 output-contains 'VSOCK-CTL: reply ok=true verb=snapshot'
vgate_assert j1 output-contains 'VSOCK-CTL: snapshot resumed'
vgate_assert j1 serial-contains 'gosnap: save J-1 ok'
vgate_assert j1 serial-contains 'gosh: attached'
vgate_assert j1 serial-contains 'pre-n=11'
vgate_assert j1 serial-contains 'vsock-ctl: suspend quiesce vlfs=synced settings=synced marker=seq=1'
vgate_assert j1 output-contains 'VSOCK-CTL: suspend paused; saving'
vgate_assert j1 output-contains 'VSOCK-CTL: suspend saved state.vzsave'
vgate_assert j1 output-contains 'VSOCK-CTL: reply ok=true verb=suspend'
vgate_assert j1 output-contains 'VSOCK-CTL: suspend stopping'
# Exactly ONE ctl reply was ever delivered in-guest: the snapshot's. The
# suspend reply is written into the frozen machine's posted buffers — its
# first post-restore read is the answer, so it can NEVER print in j1.
vgate_assert j1 serial-exact 'vsock-ctl: reply id=1 ok=true' 1
vgate_assert j1 serial-absent 'suspend: ok'
vgate_assert j1 serial-absent '[EXC]'
vgate_assert j1 python <<'PY'
import os, sys
from pathlib import Path
prof = Path(os.environ["RUN_DIR"]) / "prof.virelaivm"
state = prof / "saved-state" / "state.vzsave"
assert state.exists() and state.stat().st_size > 0, "no saved machine state"
snap = prof / "share" / "SNAPSHOTS" / "J-1.vzsave"
assert snap.exists() and snap.stat().st_size > 0, "no named snapshot"
mark = (prof / "share" / "SUSPEND.MARK").read_text()
assert mark.strip() == "virelai-suspend-request/1 seq=1", mark
print("j1: state.vzsave + SNAPSHOTS/J-1.vzsave on the profile, mark seq=1")
PY

vgate_run r1 -- --resume '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --vsock --vsock-ctl \
  --script-after 'vsock-ctl: closed' --script '$RUN_DIR/gosh-ld1.bin' \
  --script-expect 'resumed-k1' --timeout 120
vgate_allow_rc r1 0 1
vgate_assert r1 output-contains 'SUSPEND-RESUME: armed state='
vgate_assert r1 python <<'PY'
import os, re, sys
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
for needle in (b"vsock-ctl: reply id=1 ok=true", b"vsock-ctl: closed",
               b"suspend: ok", b"post-n=11", b"clip: jp-clip-1",
               b"vf: cat disk:JP-DISK.TXT size=", b"vf: cat JP-HOST.TXT size="):
    assert needle in serial, (needle, serial[-1500:])
save_ser = (run / "run-j1.serial").read_bytes()
def cksum(ser, name):
    m = re.search(rb"vf: cat (disk:)?%s size=(\d+)[\s\S]*?cksum=0x([0-9a-f]{4})" % re.escape(name), ser)
    assert m, (name, ser[-1500:])
    return m.group(2), m.group(3)
assert cksum(save_ser, b"JP-DISK.TXT") == cksum(serial, b"JP-DISK.TXT"), "/disk bytes changed"
assert cksum(save_ser, b"JP-HOST.TXT") == cksum(serial, b"JP-HOST.TXT"), "/host bytes changed"
print("r1: seat state + /disk + /host bytes intact across save/restore")
PY

vgate_file script-stage.txt <<'EOF'
sysinfo
exec GOUPD.ELF stage
EOF

vgate_file script-sysinfo.txt <<'EOF'
sysinfo
EOF

vgate_run st1 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' \
  --script '$RUN_DIR/script-stage.txt' --script-expect 'update: exit rc=' --timeout 600
vgate_assert st1 serial-contains 'vf: probe 32k ok'
vgate_assert st1 serial-contains 'owners: OWNERS.TXT loaded'
vgate_assert st1 serial-contains 'version=dev'
vgate_assert st1 serial-contains 'update: inputs KERNEL.BIN sha256='
vgate_assert st1 serial-contains 'update: staged ok version=m115g-b'
vgate_assert st1 serial-contains 'update: exit rc=0'
vgate_assert st1 python <<'PY'
import os, sys
share = os.path.join(os.environ["RUN_DIR"], "prof.virelaivm", "share", "UPDATE")
for name in ("OS.IMG", "KERNEL.BIN", "BOOTAA64.EFI", "UPDATE.MF", "UPDATE.SIG"):
    p = os.path.join(share, name)
    if not os.path.isfile(p):
        sys.exit("staged set missing " + name)
mf = open(os.path.join(share, "UPDATE.MF")).read()
for want in ("kind=image", "version=m115g-b", "KERNEL.BIN", "BOOTAA64.EFI"):
    if want not in mf:
        sys.exit("UPDATE.MF lacks " + want)
print("st1: staged UPDATE/ verified (manifest + members)")
PY

vgate_run a1 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --apply-update \
  --script '$RUN_DIR/script-sysinfo.txt' --script-expect 'uptime:' --timeout 300
vgate_assert a1 output-contains 'apply-update: applied version=m115g-b'
vgate_assert a1 output-contains 'apply-update: overlay reset'
vgate_assert a1 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert a1 serial-contains 'version=m115g-b'
vgate_assert a1 serial-absent 'version=dev'
vgate_assert a1 python <<'PY'
import hashlib, os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "prof.virelaivm", "share")
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
applied = os.path.join(share, "UPDATE.APPLIED")
if not os.path.isdir(applied):
    sys.exit("applied set was not renamed to UPDATE.APPLIED")
if h(os.path.join(run, "base.img")) != h(os.path.join(applied, "OS.IMG")):
    sys.exit("base.img != staged OS.IMG")
if h(os.path.join(run, "base.img.prev")) != h("artifacts/disk.img"):
    sys.exit("base.img.prev is not the pre-update image")
ov = os.path.join(run, "prof.virelaivm", "overlay.asif")
if not os.path.exists(ov):
    sys.exit("no overlay.asif for the applied boot")
# Iteration hygiene: the consumed-set rename is try?-idempotent, so clear
# both dirs after verifying — every later iteration's apply must mint its
# own UPDATE.APPLIED rather than leave the staged set parked.
shutil.rmtree(applied)
u = os.path.join(share, "UPDATE")
if os.path.isdir(u):
    shutil.rmtree(u)
print("a1: base swapped, .prev retained, overlay re-minted")
PY

vgate_run rb1 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --rollback-update \
  --script '$RUN_DIR/script-sysinfo.txt' --script-expect 'uptime:' --timeout 300
vgate_assert rb1 output-contains 'apply-update: rollback restored'
vgate_assert rb1 serial-contains 'version=dev'
vgate_assert rb1 serial-absent 'version=m115g-b'
vgate_assert rb1 python <<'PY'
import hashlib, os, sys
run = os.environ["RUN_DIR"]
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
if h(os.path.join(run, "base.img")) != h("artifacts/disk.img"):
    sys.exit("rollback did not restore the pre-update base")
print("rb1: rollback restored the original base image")
PY

# --- Iteration 2 -------------------------------------------------------------
vgate_file script-j2.txt <<'EOF'
clip jp-clip-2
write JP-HOST.TXT host-bytes-j2-fedcba9876543210
write /disk/JP-DISK.TXT disk-bytes-j2-fedcba9876543210
vf cat /disk/JP-DISK.TXT
vf cat JP-HOST.TXT
exec GOSNAP.ELF save J-2
EOF

vgate_run j2 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --vsock --vsock-ctl \
  --script '$RUN_DIR/script-j2.txt' \
  --script2 '$RUN_DIR/gosh-exec.txt' --script2-after 'gosnap: save J-2 ok' \
  --script3 '$RUN_DIR/gosh-sv2.bin' --script3-after 'gosh: attached' \
  --timeout 300
vgate_assert j2 serial-contains 'vsock: ready did=0x1053'
vgate_assert j2 output-contains 'VSOCK-CTL: host listener armed port=1209 suspend=armed'
vgate_assert j2 output-contains 'VSOCK-CTL: snapshot=armed restore=armed'
vgate_assert j2 serial-count 'vsock-ctl: authed' 2
vgate_assert j2 output-contains 'VSOCK-CTL: snapshot saved J-2.vzsave'
vgate_assert j2 output-contains 'VSOCK-CTL: reply ok=true verb=snapshot'
vgate_assert j2 output-contains 'VSOCK-CTL: snapshot resumed'
vgate_assert j2 serial-contains 'gosnap: save J-2 ok'
vgate_assert j2 serial-contains 'pre-n=12'
vgate_assert j2 serial-contains 'vsock-ctl: suspend quiesce vlfs=synced settings=synced marker=seq=2'
vgate_assert j2 output-contains 'VSOCK-CTL: suspend saved state.vzsave'
vgate_assert j2 output-contains 'VSOCK-CTL: reply ok=true verb=suspend'
vgate_assert j2 serial-exact 'vsock-ctl: reply id=1 ok=true' 1
vgate_assert j2 serial-absent 'suspend: ok'
vgate_assert j2 serial-absent '[EXC]'
vgate_assert j2 python <<'PY'
import os
from pathlib import Path
prof = Path(os.environ["RUN_DIR"]) / "prof.virelaivm"
state = prof / "saved-state" / "state.vzsave"
assert state.exists() and state.stat().st_size > 0, "no saved machine state"
snap = prof / "share" / "SNAPSHOTS" / "J-2.vzsave"
assert snap.exists() and snap.stat().st_size > 0, "no named snapshot"
mark = (prof / "share" / "SUSPEND.MARK").read_text()
assert mark.strip() == "virelai-suspend-request/1 seq=2", mark
PY

vgate_run r2 -- --resume '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --vsock --vsock-ctl \
  --script-after 'vsock-ctl: closed' --script '$RUN_DIR/gosh-ld2.bin' \
  --script-expect 'resumed-k2' --timeout 120
vgate_allow_rc r2 0 1
vgate_assert r2 output-contains 'SUSPEND-RESUME: armed state='
vgate_assert r2 python <<'PY'
import os, re, sys
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
for needle in (b"vsock-ctl: reply id=1 ok=true", b"vsock-ctl: closed",
               b"suspend: ok", b"post-n=12", b"clip: jp-clip-2"):
    assert needle in serial, (needle, serial[-1500:])
save_ser = (run / "run-j2.serial").read_bytes()
def cksum(ser, name):
    m = re.search(rb"vf: cat (disk:)?%s size=(\d+)[\s\S]*?cksum=0x([0-9a-f]{4})" % re.escape(name), ser)
    assert m, (name, ser[-1500:])
    return m.group(2), m.group(3)
assert cksum(save_ser, b"JP-DISK.TXT") == cksum(serial, b"JP-DISK.TXT"), "/disk bytes changed"
assert cksum(save_ser, b"JP-HOST.TXT") == cksum(serial, b"JP-HOST.TXT"), "/host bytes changed"
print("r2: seat state + /disk + /host bytes intact across save/restore")
PY

vgate_run st2 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' \
  --script '$RUN_DIR/script-stage.txt' --script-expect 'update: exit rc=' --timeout 600
vgate_assert st2 serial-contains 'vf: probe 32k ok'
vgate_assert st2 serial-contains 'owners: OWNERS.TXT loaded'
vgate_assert st2 serial-contains 'version=dev'
vgate_assert st2 serial-contains 'update: staged ok version=m115g-b'
vgate_assert st2 serial-contains 'update: exit rc=0'
vgate_assert st2 python <<'PY'
import os, sys
share = os.path.join(os.environ["RUN_DIR"], "prof.virelaivm", "share", "UPDATE")
for name in ("OS.IMG", "KERNEL.BIN", "BOOTAA64.EFI", "UPDATE.MF", "UPDATE.SIG"):
    if not os.path.isfile(os.path.join(share, name)):
        sys.exit("staged set missing " + name)
print("st2: UPDATE/ restaged on the rolled-back base")
PY

vgate_run a2 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --apply-update \
  --script '$RUN_DIR/script-sysinfo.txt' --script-expect 'uptime:' --timeout 300
vgate_assert a2 output-contains 'apply-update: applied version=m115g-b'
vgate_assert a2 serial-contains 'version=m115g-b'
vgate_assert a2 serial-absent 'version=dev'
vgate_assert a2 python <<'PY'
import hashlib, os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "prof.virelaivm", "share")
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
applied = os.path.join(share, "UPDATE.APPLIED")
if not os.path.isdir(applied):
    sys.exit("applied set was not renamed to UPDATE.APPLIED")
if h(os.path.join(run, "base.img")) != h(os.path.join(applied, "OS.IMG")):
    sys.exit("base.img != staged OS.IMG")
if h(os.path.join(run, "base.img.prev")) != h("artifacts/disk.img"):
    sys.exit("base.img.prev is not the pre-update image")
shutil.rmtree(applied)
u = os.path.join(share, "UPDATE")
if os.path.isdir(u):
    shutil.rmtree(u)
print("a2: second apply swapped the base again")
PY

vgate_run rb2 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --rollback-update \
  --script '$RUN_DIR/script-sysinfo.txt' --script-expect 'uptime:' --timeout 300
vgate_assert rb2 output-contains 'apply-update: rollback restored'
vgate_assert rb2 serial-contains 'version=dev'
vgate_assert rb2 serial-absent 'version=m115g-b'
vgate_assert rb2 python <<'PY'
import hashlib, os, sys
run = os.environ["RUN_DIR"]
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
if h(os.path.join(run, "base.img")) != h("artifacts/disk.img"):
    sys.exit("rollback did not restore the pre-update base")
print("rb2: rollback restored the original base image")
PY

# --- Iteration 3 -------------------------------------------------------------
vgate_file script-j3.txt <<'EOF'
clip jp-clip-3
write JP-HOST.TXT host-bytes-j3-13579bdf02468ace
write /disk/JP-DISK.TXT disk-bytes-j3-13579bdf02468ace
vf cat /disk/JP-DISK.TXT
vf cat JP-HOST.TXT
exec GOSNAP.ELF save J-3
EOF

vgate_run j3 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --vsock --vsock-ctl \
  --script '$RUN_DIR/script-j3.txt' \
  --script2 '$RUN_DIR/gosh-exec.txt' --script2-after 'gosnap: save J-3 ok' \
  --script3 '$RUN_DIR/gosh-sv3.bin' --script3-after 'gosh: attached' \
  --timeout 300
vgate_assert j3 serial-contains 'vsock: ready did=0x1053'
vgate_assert j3 output-contains 'VSOCK-CTL: host listener armed port=1209 suspend=armed'
vgate_assert j3 output-contains 'VSOCK-CTL: snapshot=armed restore=armed'
vgate_assert j3 serial-count 'vsock-ctl: authed' 2
vgate_assert j3 output-contains 'VSOCK-CTL: snapshot saved J-3.vzsave'
vgate_assert j3 output-contains 'VSOCK-CTL: reply ok=true verb=snapshot'
vgate_assert j3 output-contains 'VSOCK-CTL: snapshot resumed'
vgate_assert j3 serial-contains 'gosnap: save J-3 ok'
vgate_assert j3 serial-contains 'pre-n=13'
vgate_assert j3 serial-contains 'vsock-ctl: suspend quiesce vlfs=synced settings=synced marker=seq=3'
vgate_assert j3 output-contains 'VSOCK-CTL: suspend saved state.vzsave'
vgate_assert j3 output-contains 'VSOCK-CTL: reply ok=true verb=suspend'
vgate_assert j3 serial-exact 'vsock-ctl: reply id=1 ok=true' 1
vgate_assert j3 serial-absent 'suspend: ok'
vgate_assert j3 serial-absent '[EXC]'
vgate_assert j3 python <<'PY'
import os
from pathlib import Path
prof = Path(os.environ["RUN_DIR"]) / "prof.virelaivm"
state = prof / "saved-state" / "state.vzsave"
assert state.exists() and state.stat().st_size > 0, "no saved machine state"
snap = prof / "share" / "SNAPSHOTS" / "J-3.vzsave"
assert snap.exists() and snap.stat().st_size > 0, "no named snapshot"
mark = (prof / "share" / "SUSPEND.MARK").read_text()
assert mark.strip() == "virelai-suspend-request/1 seq=3", mark
PY

vgate_run r3 -- --resume '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --vsock --vsock-ctl \
  --script-after 'vsock-ctl: closed' --script '$RUN_DIR/gosh-ld3.bin' \
  --script-expect 'resumed-k3' --timeout 120
vgate_allow_rc r3 0 1
vgate_assert r3 output-contains 'SUSPEND-RESUME: armed state='
vgate_assert r3 python <<'PY'
import os, re, sys
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
for needle in (b"vsock-ctl: reply id=1 ok=true", b"vsock-ctl: closed",
               b"suspend: ok", b"post-n=13", b"clip: jp-clip-3"):
    assert needle in serial, (needle, serial[-1500:])
save_ser = (run / "run-j3.serial").read_bytes()
def cksum(ser, name):
    m = re.search(rb"vf: cat (disk:)?%s size=(\d+)[\s\S]*?cksum=0x([0-9a-f]{4})" % re.escape(name), ser)
    assert m, (name, ser[-1500:])
    return m.group(2), m.group(3)
assert cksum(save_ser, b"JP-DISK.TXT") == cksum(serial, b"JP-DISK.TXT"), "/disk bytes changed"
assert cksum(save_ser, b"JP-HOST.TXT") == cksum(serial, b"JP-HOST.TXT"), "/host bytes changed"
print("r3: seat state + /disk + /host bytes intact across save/restore")
PY

vgate_run st3 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' \
  --script '$RUN_DIR/script-stage.txt' --script-expect 'update: exit rc=' --timeout 600
vgate_assert st3 serial-contains 'vf: probe 32k ok'
vgate_assert st3 serial-contains 'owners: OWNERS.TXT loaded'
vgate_assert st3 serial-contains 'version=dev'
vgate_assert st3 serial-contains 'update: staged ok version=m115g-b'
vgate_assert st3 serial-contains 'update: exit rc=0'

vgate_run a3 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --apply-update \
  --script '$RUN_DIR/script-sysinfo.txt' --script-expect 'uptime:' --timeout 300
vgate_assert a3 output-contains 'apply-update: applied version=m115g-b'
vgate_assert a3 serial-contains 'version=m115g-b'
vgate_assert a3 serial-absent 'version=dev'
vgate_assert a3 python <<'PY'
import hashlib, os, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "prof.virelaivm", "share")
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
applied = os.path.join(share, "UPDATE.APPLIED")
if not os.path.isdir(applied):
    sys.exit("applied set was not renamed to UPDATE.APPLIED")
if h(os.path.join(run, "base.img")) != h(os.path.join(applied, "OS.IMG")):
    sys.exit("base.img != staged OS.IMG")
if h(os.path.join(run, "base.img.prev")) != h("artifacts/disk.img"):
    sys.exit("base.img.prev is not the pre-update image")
print("a3: third apply swapped the base")
PY

vgate_run rb3 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --rollback-update \
  --script '$RUN_DIR/script-sysinfo.txt' --script-expect 'uptime:' --timeout 300
vgate_assert rb3 output-contains 'apply-update: rollback restored'
vgate_assert rb3 serial-contains 'version=dev'
vgate_assert rb3 serial-absent 'version=m115g-b'
vgate_assert rb3 python <<'PY'
import hashlib, os, sys
run = os.environ["RUN_DIR"]
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
if h(os.path.join(run, "base.img")) != h("artifacts/disk.img"):
    sys.exit("rollback did not restore the pre-update base")
print("rb3: rollback restored the original base image — K=3 complete")
PY
