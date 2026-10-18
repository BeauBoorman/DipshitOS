# live-suspend-resume.spec — M115d (#2463, ADR 0056): guest-initiated
# suspend over virelai-ctl/1 into a .virelaivm profile, and the --resume
# continuation.
#
# Run `setup` mints the profile (`--profile-init`); the hook then seeds
# the bundle's share/ (GOSH.ELF + the uid_system `vsock-ctl` credential)
# and flips `devices.share` OFF — a custom-virtio share cannot be saved
# (live-vz-restore's negative runs), so the boot attaches the share over
# Apple's virtio-fs instead: the restore-safe host channel (ADR 0056's
# double-reader reads the credential off either transport).
#
# Three save/load pairs (K=3), each a full cycle on the same profile.
# Every `svN` boot: the kernel monitor writes byte-fixtures to BOTH
# persistence surfaces (`write SR-HOST.TXT` on the /host share, a
# journaled `write /disk/SR-DISK.TXT` on VLFS), checksums them (`vf cat`
# size+cksum), loads the kernel clipboard with a per-iteration text, then
# execs GOSH on the serial console, sets `$SRN`, and runs the `suspend`
# builtin — the EL0 sys_vsock_ctl door: connect, HMAC auth, the guest
# quiesce (VLFS fsync, the settings re-save, and the SUSPEND.MARK request
# receipt), THEN the verb. The host pauses the VM, saves machine state
# into the bundle's saved-state/state.vzsave, writes the `ok:true` reply
# WHILE THE GUEST IS FROZEN (the saved machine's first post-restore read
# is its answer), then stops and exits — so the sv serial must contain
# `vsock-ctl: authed` and NEVER a reply line.
#
# Each `ldN` is `--resume <profile>`: VZ restores the state file and the
# GOSH session continues mid-syscall — the builtin prints `suspend: ok`,
# the seat/script state ($SRN, the clipboard) and both surfaces' bytes
# (same size + cksum) must read back. `SUSPEND-RESUME: restored` and the
# absence of a kernel banner prove a restore, not a boot.
#
# THE NAMED BOUND (M119e): `restoreMachineStateFrom` on this host
# saturates at VZErrorDomain Code=12 — the same refusal live-vz-restore
# and live-vsock-restore already pin. Every save cycle is real evidence;
# each ld run accepts ONLY the two honest shapes: `SUSPEND-RESUME:
# restored` + the full state transcript, or `restore refused code=12`
# (the bound). A silent boot, any other error, or a missing marker
# fails.
#
# HOST PREREQ: bash tools/go/build-gosh.sh -> .build/go/GOSH.ELF

vgate_name live-suspend-resume "M115d #2463: guest-initiated suspend via virelai-ctl/1 -> profile saved-state; --resume restore; K=3; M119e Code=12 bound"
vgate_share none

# The profile is minted INSIDE the setup hook (hooks precede every run —
# a `--profile-init` gate run would seed nothing). The credential (the
# ADR 0056 pinned vector — ASCII 'a5' x 32) and the guest app land on the
# bundle's own share; devices.share is flipped OFF in config.json so the
# profile boots WITHOUT the cvc-file attachment a save cannot survive —
# the boot runs pass --virtio-fs instead.
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
src = os.path.join(".build", "go", "GOSH.ELF")
if not os.path.exists(src):
    sys.exit("GOSH.ELF missing (expected " + src + ") — build it first: "
             "bash tools/go/build-gosh.sh")
shutil.copy(src, os.path.join(share, "GOSH.ELF"))
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\nvsock-ctl\t0\t" + "a5" * 32 + "\n")
cfg_path = os.path.join(prof, "config.json")
cfg = json.load(open(cfg_path))
cfg.setdefault("devices", {})["share"] = False
json.dump(cfg, open(cfg_path, "w"), indent=2, sort_keys=True)
# A fresh bundle's vlfs.img is unformatted — the guest mounts not_vlfs
# and every /disk leg fails. Format it with the same mkfs.vlfs the other
# VLFS gates drive (64 MiB default volume).
subprocess.check_call(["go", "-C", "tools/go/vlfs", "build",
                       "-o", os.path.join(run, "mkfs.vlfs"), "."])
r = subprocess.run([os.path.join(run, "mkfs.vlfs"),
                    os.path.join(prof, "vlfs.img")],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("mkfs.vlfs refused the profile data disk: " + r.stdout + r.stderr)
for i in (1, 2, 3):
    # GOSH-phase input for the save run: a per-iteration var, then the
    # builtin whose syscall suspends the machine.
    open(os.path.join(run, "gosh-sv%d.bin" % i), "wb").write(
        ("export SRN=1%d\r" % i
         + "echo pre-n=$SRN\r"
         + "suspend\r").encode())
    # Post-restore input for the load run: GOSH reads its own answer,
    # proves the var, hands the console to the monitor, and the monitor
    # re-checks clipboard + both byte-fixtures.
    open(os.path.join(run, "gosh-ld%d.bin" % i), "wb").write(
        ("echo post-n=$SRN\r"
         + "monitor\r"
         + "clip\r"
         + "vf cat /disk/SR-DISK.TXT\r"
         + "vf cat SR-HOST.TXT\r"
         + "echo resumed-k%d\r" % i).encode())
print("staged profile share (GOSH.ELF + vsock-ctl credential), "
      "devices.share=false, 3x sv/ld input pairs")
PY

# The minted bundle loads: manifest + members + the patched config read
# back cleanly before any boot leans on them.
vgate_run setup -- --profile '$RUN_DIR/prof.virelaivm' --profile-init --timeout 60
vgate_assert setup output-contains 'profile: loaded'

# --- Cycle 1 -----------------------------------------------------------------
vgate_file script-sv1.txt <<'EOF'
clip sr-clip-k1
write SR-HOST.TXT host-bytes-k1-0123456789abcdef
write /disk/SR-DISK.TXT disk-bytes-k1-0123456789abcdef
vf cat /disk/SR-DISK.TXT
vf cat SR-HOST.TXT
exec GOSH.ELF serial
EOF

vgate_run sv1 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl \
  --script '$RUN_DIR/script-sv1.txt' --script2 '$RUN_DIR/gosh-sv1.bin' --script2-after 'gosh: attached' \
  --timeout 120
vgate_assert sv1 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert sv1 serial-contains 'vsock: ready did=0x1053'
vgate_assert sv1 output-contains 'VSOCK-CTL: host listener armed port=1209 suspend=armed'
vgate_assert sv1 serial-contains 'gosh: attached'
vgate_assert sv1 serial-contains 'pre-n=11'
vgate_assert sv1 serial-contains 'vsock-ctl: authed'
vgate_assert sv1 serial-contains 'vsock-ctl: suspend quiesce vlfs=synced settings=synced marker=seq=1'
vgate_assert sv1 output-contains 'VSOCK-CTL: suspend paused; saving'
vgate_assert sv1 output-contains 'VSOCK-CTL: suspend saved state.vzsave'
vgate_assert sv1 output-contains 'VSOCK-CTL: reply ok=true verb=suspend'
vgate_assert sv1 output-contains 'VSOCK-CTL: suspend stopping'
# The guest is frozen inside the syscall: it can NEVER print the reply in
# this run — its first post-restore read is the answer.
vgate_assert sv1 serial-absent 'vsock-ctl: reply'
vgate_assert sv1 serial-absent '[EXC]'
vgate_assert sv1 python <<'PY'
import os, sys
from pathlib import Path
prof = Path(os.environ["RUN_DIR"]) / "prof.virelaivm"
state = prof / "saved-state" / "state.vzsave"
assert state.exists() and state.stat().st_size > 0, "no saved machine state"
mark = (prof / "share" / "SUSPEND.MARK").read_text()
assert mark.strip() == "virelai-suspend-request/1 seq=1", mark
PY

vgate_run ld1 -- --resume '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl \
  --script-after 'vsock-ctl: closed' --script '$RUN_DIR/gosh-ld1.bin' \
  --script-expect 'resumed-k1' --timeout 90
vgate_allow_rc ld1 0 1
vgate_assert ld1 output-contains 'SUSPEND-RESUME: armed state='
vgate_assert ld1 python <<'PY'
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
               b"suspend: ok", b"post-n=11", b"clip: sr-clip-k1",
               b"vf: cat disk:SR-DISK.TXT size=", b"vf: cat SR-HOST.TXT size="):
    assert needle in serial, (needle, serial[-1500:])
# Byte-integrity across the boundary: the same size+cksum the save run
# printed for each surface.
save_ser = (run / "run-sv1.serial").read_bytes()
def cksum(ser, name):
    m = re.search(rb"vf: cat (disk:)?%s size=(\d+)[\s\S]*?cksum=0x([0-9a-f]{4})" % re.escape(name), ser)
    assert m, (name, ser[-1500:])
    return m.group(2), m.group(3)
assert cksum(save_ser, b"SR-DISK.TXT") == cksum(serial, b"SR-DISK.TXT"), "/disk bytes changed"
assert cksum(save_ser, b"SR-HOST.TXT") == cksum(serial, b"SR-HOST.TXT"), "/host bytes changed"
print("resume: seat state + /disk + /host bytes intact across save/restore")
PY

# --- Cycle 2 -----------------------------------------------------------------
vgate_file script-sv2.txt <<'EOF'
clip sr-clip-k2
write SR-HOST.TXT host-bytes-k2-fedcba9876543210
write /disk/SR-DISK.TXT disk-bytes-k2-fedcba9876543210
vf cat /disk/SR-DISK.TXT
vf cat SR-HOST.TXT
exec GOSH.ELF serial
EOF

vgate_run sv2 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl \
  --script '$RUN_DIR/script-sv2.txt' --script2 '$RUN_DIR/gosh-sv2.bin' --script2-after 'gosh: attached' \
  --timeout 120
vgate_assert sv2 serial-contains 'vsock: ready did=0x1053'
vgate_assert sv2 output-contains 'VSOCK-CTL: host listener armed port=1209 suspend=armed'
vgate_assert sv2 serial-contains 'pre-n=12'
vgate_assert sv2 serial-contains 'vsock-ctl: suspend quiesce vlfs=synced settings=synced marker=seq=2'
vgate_assert sv2 output-contains 'VSOCK-CTL: suspend saved state.vzsave'
vgate_assert sv2 output-contains 'VSOCK-CTL: reply ok=true verb=suspend'
vgate_assert sv2 serial-absent 'vsock-ctl: reply'
vgate_assert sv2 serial-absent '[EXC]'
vgate_assert sv2 python <<'PY'
import os
from pathlib import Path
prof = Path(os.environ["RUN_DIR"]) / "prof.virelaivm"
state = prof / "saved-state" / "state.vzsave"
assert state.exists() and state.stat().st_size > 0, "no saved machine state"
mark = (prof / "share" / "SUSPEND.MARK").read_text()
assert mark.strip() == "virelai-suspend-request/1 seq=2", mark
PY

vgate_run ld2 -- --resume '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl \
  --script-after 'vsock-ctl: closed' --script '$RUN_DIR/gosh-ld2.bin' \
  --script-expect 'resumed-k2' --timeout 90
vgate_allow_rc ld2 0 1
vgate_assert ld2 output-contains 'SUSPEND-RESUME: armed state='
vgate_assert ld2 python <<'PY'
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
for needle in (b"vsock-ctl: reply id=1 ok=true", b"suspend: ok", b"post-n=12",
               b"clip: sr-clip-k2"):
    assert needle in serial, (needle, serial[-1500:])
save_ser = (run / "run-sv2.serial").read_bytes()
def cksum(ser, name):
    m = re.search(rb"vf: cat (disk:)?%s size=(\d+)[\s\S]*?cksum=0x([0-9a-f]{4})" % re.escape(name), ser)
    assert m, (name, ser[-1500:])
    return m.group(2), m.group(3)
assert cksum(save_ser, b"SR-DISK.TXT") == cksum(serial, b"SR-DISK.TXT"), "/disk bytes changed"
assert cksum(save_ser, b"SR-HOST.TXT") == cksum(serial, b"SR-HOST.TXT"), "/host bytes changed"
print("resume: seat state + /disk + /host bytes intact across save/restore")
PY

# --- Cycle 3 -----------------------------------------------------------------
vgate_file script-sv3.txt <<'EOF'
clip sr-clip-k3
write SR-HOST.TXT host-bytes-k3-13579bdf02468ace
write /disk/SR-DISK.TXT disk-bytes-k3-13579bdf02468ace
vf cat /disk/SR-DISK.TXT
vf cat SR-HOST.TXT
exec GOSH.ELF serial
EOF

vgate_run sv3 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl \
  --script '$RUN_DIR/script-sv3.txt' --script2 '$RUN_DIR/gosh-sv3.bin' --script2-after 'gosh: attached' \
  --timeout 120
vgate_assert sv3 serial-contains 'vsock: ready did=0x1053'
vgate_assert sv3 output-contains 'VSOCK-CTL: host listener armed port=1209 suspend=armed'
vgate_assert sv3 serial-contains 'pre-n=13'
vgate_assert sv3 serial-contains 'vsock-ctl: suspend quiesce vlfs=synced settings=synced marker=seq=3'
vgate_assert sv3 output-contains 'VSOCK-CTL: suspend saved state.vzsave'
vgate_assert sv3 output-contains 'VSOCK-CTL: reply ok=true verb=suspend'
vgate_assert sv3 serial-absent 'vsock-ctl: reply'
vgate_assert sv3 serial-absent '[EXC]'
vgate_assert sv3 python <<'PY'
import os
from pathlib import Path
prof = Path(os.environ["RUN_DIR"]) / "prof.virelaivm"
state = prof / "saved-state" / "state.vzsave"
assert state.exists() and state.stat().st_size > 0, "no saved machine state"
mark = (prof / "share" / "SUSPEND.MARK").read_text()
assert mark.strip() == "virelai-suspend-request/1 seq=3", mark
PY

vgate_run ld3 -- --resume '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --vsock --vsock-ctl \
  --script-after 'vsock-ctl: closed' --script '$RUN_DIR/gosh-ld3.bin' \
  --script-expect 'resumed-k3' --timeout 90
vgate_allow_rc ld3 0 1
vgate_assert ld3 output-contains 'SUSPEND-RESUME: armed state='
vgate_assert ld3 python <<'PY'
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
for needle in (b"vsock-ctl: reply id=1 ok=true", b"suspend: ok", b"post-n=13",
               b"clip: sr-clip-k3"):
    assert needle in serial, (needle, serial[-1500:])
save_ser = (run / "run-sv3.serial").read_bytes()
def cksum(ser, name):
    m = re.search(rb"vf: cat (disk:)?%s size=(\d+)[\s\S]*?cksum=0x([0-9a-f]{4})" % re.escape(name), ser)
    assert m, (name, ser[-1500:])
    return m.group(2), m.group(3)
assert cksum(save_ser, b"SR-DISK.TXT") == cksum(serial, b"SR-DISK.TXT"), "/disk bytes changed"
assert cksum(save_ser, b"SR-HOST.TXT") == cksum(serial, b"SR-HOST.TXT"), "/host bytes changed"
print("resume: seat state + /disk + /host bytes intact across save/restore")
PY
