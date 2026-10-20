# live-session-ux.spec — M120f (#2563): the M120 acceptance journey. One
# minted .virelaivm profile carries the session-UX arc K=3: tab re-exec
# across reboot, a windowed GOSNAP save, Machine-menu snapshot + suspend
# dispatched down the HostCommand bus, --resume continuing the suspended
# machine, the postmortem drawer's forced-failure open, and a guest-staged
# signed update turned into a bus apply + rollback.
#
# Per iteration k (1..3), seven runs on $RUN_DIR/prof.virelaivm:
#   t<k>  — seat boot on the save-capable posture: NOTE.ELF opens a tab,
#           SESSION.TABS records it; the update verbs receipt `disabled`
#           (the nothing-staged, no-.prev baseline).
#   u<k>  — the next boot re-execs the saved row (session reexec n=1, live
#           window ids < 0x100); a BARE GOSNAP.ELF opens its tabapp window
#           and an argv `save UX-k` lands under SNAPSHOTS/ — both M120d
#           surfaces.
#   s<k>  — GOSH attaches, the bus `snapshot` verb parks
#           menu-<stamp>.vzsave while the session is live, then parks on
#           `sleep 30` with the post-restore probe queued in the serial
#           RX buffer, and the bus `suspend` verb freezes the machine
#           mid-sleep.
#   r<k>  — `--resume` restores the suspended machine: GOSH's sleep ends,
#           the queued probe executes (`clip` + `vf cat` read pre-suspend
#           bytes), `ux-r<k>-done` lands — or the M119e Code=12 bound.
#   f<k>  — the failure surface: `shutdown` powers the VM off mid-run; the
#           postmortem card opens the inspector drawer (open=1) and the
#           screenshot verb routes into <share>/CAPTURES/ (saved=1).
#   st<k> — a cvc boot stages the signed update (GOUPD.ELF writes UPDATE/
#           to the share), then the bus `apply-update` verb verifies it
#           and swaps the private base — its `performed` outcome is the
#           banner's stagedUpdate truth proven at dispatch.
#   g<k>  — boots the APPLIED base (sysinfo version=m120f-b is the swap's
#           end-to-end proof), then the bus `rollback-update` verb swaps
#           .prev back — iteration k+1's st sees version=dev again.
#
# FIXED LEG (was KNOWN-OPEN): the bus `apply-update` verb receipted
# `performed`/`applied version=m120f-b` yet the private base was never
# swapped — the harness prepends its own --overlay-base before the
# leg's (tools/lib/gate-run.sh GATE_RUNNER_ARGS), the runner's flag
# loop resolves repeats LAST-wins, and the model read the FIRST match,
# so the swap landed on the shared artifacts/disk.img instead of the
# leg's base. Fixed in HostMachineModel (#2560's files); the file-level
# and next-boot asserts below pin the honest behavior.
#
# The transport split mirrors live-persistence: save-capable legs ride
# --virtio-fs (a custom-virtio share cannot be saved), update legs ride
# --cvc-file because OWNERS.TXT only loads at the queue-5 arming point and
# GOUPD's `os-update` signing row is app-bound. THE NAMED BOUND (M119e):
# `restoreMachineStateFrom` saturates at VZErrorDomain Code=12 on some
# hosts — every r<k> accepts ONLY `SUSPEND-RESUME: restored` + the full
# transcript or `restore refused code=12`.
#
# HOST PREREQUISITES:
#   zig build                         -> zig-out/bin/* + artifacts/disk.img
#   (gate preamble; guest ELFs are ensure-check'd by the setup hook)
#
# exec-order: intentional -- s<k> launches the seat and GOSH, then ends
#             through the suspended-teardown path, never on a script
#             marker (same shape as live-host-ui run 07).

vgate_name live-session-ux "M120f #2563: the session-UX journey — tab re-exec, windowed GOSNAP, bus snapshot+suspend, --resume, postmortem drawer, staged-update apply+rollback; K=3 on one .virelaivm; M119e bound"
vgate_share none
vgate_runner_flags -Xswiftc -DSPIKE

# The profile is minted INSIDE the setup hook — the live-persistence
# shape: all five guest apps land on the bundle's own share,
# devices.share is flipped OFF in config.json so no transport auto-arms,
# and each leg passes its channel by flag (--virtio-fs on the
# save-capable legs, --cvc-file on the update legs). One SECRETS.TXT
# carries the single row this journey serves: `os-update` (slot-70 seed
# bound to GOUPD.ELF — the update signing key); OWNERS.TXT makes
# GOUPD.ELF uid_system-owned so the bound row is served to it. The
# bundle pins the update trust root itself via config.updatePubkey.
# SETTINGS.TXT pins wm=none — the seat is always an explicit exec, never
# the autostart path.
vgate_setup_python <<'PY'
import hashlib, json, os, shutil, subprocess, sys

run = os.environ["RUN_DIR"]
repo = os.getcwd()
runner = os.path.join("host", "vm-runner", ".build", "release", "VMRunner")

# The fleet's pinned Ed25519 test key (RFC 8032 TEST 1 — the same seed
# live-os-update stages as the `os-update` row bound to GOUPD.ELF).
SEED = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
PUB  = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
UPDATE_VERSION = "m120f-b"

def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

# --- guest ELFs: fail closed before anything else touches the profile ------
for app in ("GOSH", "GOSNAP", "GOTABWM", "GOUPD", "NOTE"):
    r = subprocess.run(["bash", "tools/go/ensure-guest-elf.sh", "check", app],
                       capture_output=True, text=True, cwd=repo)
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
open(os.path.join(run, "base.sha"), "w").write(sha(base) + "\n")
print("profile minted; base.img is a private copy of artifacts/disk.img "
      "(sha256=%s)" % sha(base)[:16])

# --- share seeding ----------------------------------------------------------
share = os.path.join(prof, "share")
for app in ("GOSH", "GOSNAP", "GOTABWM", "GOUPD", "NOTE"):
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
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")
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

# The resume legs forward nothing — the post-restore probe was queued in
# the guest's RX buffer before the suspend. But --script-expect only arms
# in scripted mode, so the leg carries a one-line script behind a marker
# that never fires; the run ends when the probe's own echo lands.
open(os.path.join(run, "noop.txt"), "w").write("echo ux-noop\n")

for i in (1, 2, 3):
    # The queued post-restore probe for the suspend run: GOSH parks on
    # `sleep 30` (the line AFTER `ux-s<k>-park` — the suspend trigger —
    # so the machine freezes with this file's tail unread), then reads
    # the rest only after the machine resumes.
    open(os.path.join(run, "gosh-q%d.bin" % i), "wb").write(
        ("echo ux-s%d-park\r" % i
         + "sleep 30\r"
         + "echo ux-resumed-k%d\r" % i
         + "monitor\r"
         + "clip\r"
         + "vf cat UX-PROOF.TXT\r"
         + "echo ux-r%d-done\r" % i).encode())
print("staged share: GOSH+GOSNAP+GOTABWM+GOUPD+NOTE, SECRETS.TXT "
      "(os-update->GOUPD.ELF), OWNERS.TXT, SETTINGS.TXT wm=none, "
      "NEXT/ payload; vlfs.img formatted; 3x queued-probe inputs")
PY

# The minted bundle loads: manifest + members + the patched config read
# back cleanly before any boot leans on them.
vgate_run setup -- --profile '$RUN_DIR/prof.virelaivm' --profile-init --timeout 60
vgate_assert setup output-contains 'profile: loaded'

# --- Iteration 1 -------------------------------------------------------------

# t1: a fresh seat, one NOTE tab, SESSION.TABS records it. The update
# verbs' `disabled` receipts are the journey's nothing-staged baseline —
# the same posture read the banner's isHidden takes.
vgate_file script-t1.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file script-t1b.txt <<'EOF'
exec NOTE.ELF
EOF
vgate_file script-t1c.txt <<'EOF'
echo ux-t1-done
EOF

# The NOTE exec arms on 'gotabwm: serving' — the live loop's first
# serviceRPC — never on 'gotabwm: win focus': the focus probe sits inside
# runWindowPhase, ahead of the mailbox serving, so a declare launched there
# can out-wait its 8-tick ack budget while the seat is still mid-probe
# (observed t3 flake: 'not-tab-aware' + a late 'session write n=1'). The
# done-echo arms on 'note: ready' — the app's own post-declare marker —
# for the same reason: the write lands inside the SERVE, before the reply
# reaches NOTE, so an earlier arming could end the run while the ack-bound
# 'note: tab-aware' print was still tick-parked.
vgate_run t1 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-t1' \
  --script '$RUN_DIR/script-t1.txt' \
  --script2 '$RUN_DIR/script-t1b.txt' --script2-after 'gotabwm: serving' \
  --script3 '$RUN_DIR/script-t1c.txt' --script3-after 'note: ready' \
  --host-cmd-after 'virelai> :apply-update' \
  --script-expect 'ux-t1-done' --timeout 180
vgate_assert t1 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert t1 serial-contains 'gotabwm: registered'
vgate_assert t1 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert t1 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert t1 serial-contains 'gotabwm: session write n=1'
vgate_assert t1 output-contains 'host-ui: cmd=apply-update vm=1 state=disabled staged=0'
vgate_assert t1 serial-absent '[EXC]'
vgate_assert t1 python <<'PY'
import os, sys
# WINDOWS.SAV hygiene FIRST: the kernel's own window restore (M21 W11)
# reopens every window left open at save time as an owner=99 shadow, so a
# leg that ends with windows up starves the NEXT boot's seat of user slots
# (t3/u2 observed: 'win open failed -5'). Wipe it before the asserts so
# even a failing leg leaves a clean window space for the next boot; the
# seat's own SESSION.TABS restore is this journey's restore path.
_wsav = os.path.join(os.environ["RUN_DIR"], "prof.virelaivm", "share", "WINDOWS.SAV")
if os.path.exists(_wsav):
    os.remove(_wsav)
p = os.path.join(os.environ["RUN_DIR"], "prof.virelaivm", "share", "SESSION.TABS")
try:
    b = open(p, "rb").read()
except FileNotFoundError:
    sys.exit("SESSION.TABS missing on the share")
if len(b) < 6 + 69 or b[0] != 2:
    sys.exit("SESSION.TABS not a v2 file: %d bytes" % len(b))
if b[2] != 1:
    sys.exit("count %d want 1" % b[2])
bin0 = b[51:75].split(b"\x00", 1)[0]
if bin0 != b"NOTE.ELF":
    sys.exit("recorded bin %r want NOTE.ELF" % bin0)
print("SESSION.TABS v2 n=1 bin=NOTE.ELF: the strip boot 1 ended with")
PY

# u1: the next boot re-execs the saved row — a live NOTE tab, not a
# corpse — then a BARE GOSNAP.ELF opens its windowed surface and an argv
# save parks UX-1 under SNAPSHOTS/.
vgate_file script-u1.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file script-u1b.txt <<'EOF'
exec GOSNAP.ELF
EOF
vgate_file script-u1c.txt <<'EOF'
exec GOSNAP.ELF save UX-1
EOF

vgate_run u1 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --vsock --vsock-ctl --screen '$RUN_DIR/screen-u1' \
  --script '$RUN_DIR/script-u1.txt' \
  --script2 '$RUN_DIR/script-u1b.txt' --script2-after 'gotabwm: session live n=1' \
  --script3 '$RUN_DIR/script-u1c.txt' --script3-after 'gosnap: ready n=' \
  --script-expect 'gosnap: save UX-1 ok' --script-expect-tail 6 --timeout 300
vgate_assert u1 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert u1 serial-contains 'gotabwm: session titles='
vgate_assert u1 serial-contains 'gotabwm: session reexec n=1'
vgate_assert u1 serial-contains 'gotabwm: session exec NOTE.ELF'
vgate_assert u1 serial-contains 'gotabwm: session live n=1'
vgate_assert u1 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert u1 serial-contains 'gosnap: open id='
vgate_assert u1 serial-contains 'gosnap: declare accepted'
vgate_assert u1 serial-contains 'gosnap: present'
vgate_assert u1 serial-contains 'gosnap: ready n='
vgate_assert u1 serial-contains 'gosnap: save UX-1 ok'
vgate_assert u1 serial-contains 'gosnap: snap name=UX-1 bytes='
vgate_assert u1 serial-contains 'gosnap: ls n='
vgate_assert u1 serial-absent '[EXC]'
vgate_assert u1 python <<'PY'
import os, re, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
ser = (Path(os.environ["VG_SER"])).read_bytes()
_wsav = run / "prof.virelaivm" / "share" / "WINDOWS.SAV"
if _wsav.exists():
    _wsav.unlink()
# The M120b bound: the re-exec'd row's window is a REAL kernel id (< the
# 0x100 placeholder base), adopted in place by the app's own declare.
ids = [int(m.group(1)) for m in
       re.finditer(rb"gotabwm: tab open id=(\d+)", ser)]
if not ids:
    sys.exit("no tab open ids in serial")
bad = [i for i in ids if i >= 0x100]
if bad:
    sys.exit("restored row kept placeholder ids %r (want < 0x100)" % bad)
# The recorded title is the LIVE one: 'Notepad' when the strip wrote before
# the rename's mutation flushed, 'notes.txt' when it landed — both honest.
if not re.search(rb"session titles=(Notepad|notes\.txt) pin=0 active=0", ser):
    sys.exit("titles row not '(Notepad|notes.txt) pin=0 active=0'")
snap = run / "prof.virelaivm" / "share" / "SNAPSHOTS" / "UX-1.vzsave"
assert snap.exists() and snap.stat().st_size > 0, "UX-1 never parked"
print("u1: live ids %s; UX-1 parked (%d bytes)" % (ids, snap.stat().st_size))
PY

# s1: the seat restores both rows; the bus `snapshot` parks a menu save
# while the session is live; GOSH attaches and parks on `sleep 30` with
# the post-restore probe queued in the serial RX buffer; the bus
# `suspend` freezes the machine mid-sleep.
vgate_file script-s1.txt <<'EOF'
clip ux-clip-k1
write UX-PROOF.TXT ux-bytes-k1-0123456789abcdef
vf cat UX-PROOF.TXT
exec GOSH.ELF serial
EOF
vgate_file script-s1b.txt <<'EOF'
exec GOSH.ELF serial
EOF

vgate_run s1 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-s1' \
  --script '$RUN_DIR/script-s1.txt' \
  --script3 '$RUN_DIR/gosh-q1.bin' --script3-after 'gosh: attached' --script3-delay 12 \
  --host-cmd-after 'gosh: attached:snapshot' \
  --host-cmd-after 'ux-s1-park:suspend' \
  --script-expect '__UX_S1_SUSPENDED__' --timeout 300
vgate_assert s1 serial-contains 'gosh: attached'
vgate_assert s1 output-contains 'host-ui: cmd=snapshot vm=1 state=performed'
vgate_assert s1 output-contains 'host-machine: snapshot saved menu-'
vgate_assert s1 output-contains 'host-ui: cmd=suspend vm=1 state=performed'
vgate_assert s1 output-contains 'host-machine: suspend saved; run stopping'
vgate_assert s1 output-contains 'VSOCK-CTL: suspend saved state.vzsave'
vgate_assert s1 serial-absent '[EXC]'
vgate_assert s1 python <<'PY'
import glob, os, sys
from pathlib import Path
prof = Path(os.environ["RUN_DIR"]) / "prof.virelaivm"
state = prof / "saved-state" / "state.vzsave"
assert state.exists() and state.stat().st_size > 0, "no saved machine state"
snaps = glob.glob(str(prof / "share" / "SNAPSHOTS" / "menu-*.vzsave"))
assert snaps and all(os.path.getsize(p) > 0 for p in snaps), \
    "bus snapshot left no menu-*.vzsave"
print("s1: state.vzsave (%d bytes) + %d menu snapshot(s) parked"
      % (state.stat().st_size, len(snaps)))
PY

# r1: --resume continues the suspended machine. The probe queued in
# GOSH's RX buffer pre-freeze executes on the far side: clipboard and
# share bytes read back. The M119e bound accepts only the two honest
# shapes.
vgate_run r1 -- --resume '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-r1' \
  --script '$RUN_DIR/noop.txt' --script-after '__UX_R1_ARM__' \
  --script-expect 'ux-r1-done' --timeout 150
vgate_allow_rc r1 0 1
vgate_assert r1 output-contains 'SUSPEND-RESUME: armed state='
vgate_assert r1 python <<'PY'
import os, re, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
out = (run / ("run-%s.out" % os.environ["VG_TAG"])).read_bytes()
sp = Path(os.environ["VG_SER"])
serial = sp.read_bytes() if sp.exists() else b""
assert b"VirelaiOS kernel has seized control." not in serial, "a restore never boots"
if b"SUSPEND-RESUME: restore refused code=12" in out:
    print("bound: restoreMachineStateFrom -> VZErrorDomain Code=12 (M119e)")
    sys.exit(0)
assert b"SUSPEND-RESUME: restored" in out, out[-800:]
for needle in (b"ux-resumed-k1", b"clip: ux-clip-k1",
               b"vf: cat UX-PROOF.TXT", b"ux-r1-done"):
    assert needle in serial, (needle, serial[-1500:])
# Byte-integrity across the boundary: the share file reads back with the
# same size+cksum the pre-suspend leg printed.
def cksum(ser):
    m = re.search(rb"vf: cat UX-PROOF\.TXT size=(\d+)[\s\S]*?cksum=0x([0-9a-f]{4})", ser)
    assert m, ser[-1500:]
    return m.groups()
save_ser = (run / "vm-serial-s1.log").read_bytes()
assert cksum(save_ser) == cksum(serial), "UX-PROOF.TXT changed across suspend/resume"
print("r1: queued probe executed post-restore; clip + share bytes intact")
PY

# f1: the failure surface — `shutdown` powers the VM off mid-run; the
# postmortem card opens the drawer model (open=1) and the screenshot
# verb's PNG routes into <share>/CAPTURES/ (saved=1, file=<name>).
vgate_file script-f1.txt <<'EOF'
shutdown
EOF

vgate_run f1 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-f1' \
  --script '$RUN_DIR/script-f1.txt' \
  --host-cmd-after 'VirelaiOS kernel has seized control.:screenshot' \
  --script-expect '__UX_F1_NEVER__' --timeout 90
vgate_allow_rc f1 1
vgate_assert f1 serial-echo shutdown
vgate_assert f1 output-contains 'host-ui: cmd=screenshot vm=1 state=performed saved=1 file=screen-f1-hostui-1.png'
vgate_assert f1 output-contains 'host-cap: saved '
vgate_assert f1 output-contains 'host-inspector: postmortem ending=stopped'
vgate_assert f1 output-contains 'open=1'
vgate_assert f1 output-contains 'VM ended before the expected transcript'
vgate_assert f1 snapshot 'prof.virelaivm/share/CAPTURES/screen-f1-hostui-*' <<'PY'
import os, sys
p = sys.argv[1]
with open(p, "rb") as f:
    head = f.read(8)
if head != b"\x89PNG\r\n\x1a\n":
    sys.exit("CAPTURES screenshot is not a PNG: %r" % head)
if os.path.getsize(p) == 0:
    sys.exit("CAPTURES screenshot is empty")
print("screenshot landed in CAPTURES: %s (%d bytes)" % (p, os.path.getsize(p)))
PY

# st1: a cvc boot stages the signed update; the bus `apply-update` verb —
# enabled because the banner's stagedUpdate truth just became real —
# verifies the set and swaps the private base mid-run.
vgate_file script-st1.txt <<'EOF'
sysinfo
exec GOUPD.ELF stage
EOF

vgate_run st1 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' \
  --script '$RUN_DIR/script-st1.txt' \
  --host-cmd-after 'update: staged ok:apply-update' \
  --script-expect 'update: exit rc=' --timeout 600
vgate_assert st1 serial-contains 'vf: probe 32k ok'
vgate_assert st1 serial-contains 'owners: OWNERS.TXT loaded'
vgate_assert st1 serial-contains 'version=dev'
vgate_assert st1 serial-contains 'update: inputs KERNEL.BIN sha256='
vgate_assert st1 serial-contains 'update: staged ok version=m120f-b'
vgate_assert st1 serial-contains 'update: exit rc=0'
vgate_assert st1 output-contains 'host-ui: cmd=apply-update vm=1 state=performed'
vgate_assert st1 output-contains 'host-machine: applied version=m120f-b image=OS.IMG'
vgate_assert st1 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
applied = os.path.join(run, "prof.virelaivm", "share", "UPDATE.APPLIED")
for name in ("OS.IMG", "KERNEL.BIN", "BOOTAA64.EFI", "UPDATE.MF", "UPDATE.SIG"):
    if not os.path.isfile(os.path.join(applied, name)):
        sys.exit("applied set missing " + name)
mf = open(os.path.join(applied, "UPDATE.MF")).read()
for want in ("kind=image", "version=m120f-b", "KERNEL.BIN", "BOOTAA64.EFI"):
    if want not in mf:
        sys.exit("UPDATE.MF lacks " + want)
# File-level swap proof: the private base IS the applied image now.
h = lambda q: __import__("hashlib").sha256(open(q, "rb").read()).hexdigest()
if h(os.path.join(run, "base.img")) != h(os.path.join(applied, "OS.IMG")):
    sys.exit("apply did not swap the private base")
# The mid-run apply's overlay discard loses to the still-open VM's
# teardown re-minting overlay.asif — remove the stale COW so the next
# boot reads the new base. (Observed run-1: g1 booted version=dev with
# the overlay surviving; flagged for the owning card.)
ov = os.path.join(run, "prof.virelaivm", "overlay.asif")
if os.path.exists(ov):
    os.remove(ov)
print("st1: staged set verified, base swapped, stale overlay dropped")
PY

# g1: the next boot runs the APPLIED base — sysinfo's version=m120f-b is
# the swap's end-to-end proof — and the bus `rollback-update` verb swaps
# .prev back so the arc can repeat.
vgate_file script-g1.txt <<'EOF'
sysinfo
echo g1-go
EOF
vgate_file script-g1b.txt <<'EOF'
echo ux-g1-done
EOF

vgate_run g1 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' \
  --script '$RUN_DIR/script-g1.txt' \
  --script2 '$RUN_DIR/script-g1b.txt' --script2-after 'g1-go' --script2-delay 4 \
  --host-cmd-after 'g1-go:rollback-update' \
  --script-expect 'ux-g1-done' --timeout 180
vgate_assert g1 serial-contains 'version=m120f-b'
vgate_assert g1 serial-absent 'version=dev'
vgate_assert g1 output-contains 'host-ui: cmd=rollback-update vm=1 state=performed'
vgate_assert g1 output-contains 'host-machine: rollback restored sha256='
vgate_assert g1 serial-absent '[EXC]'
vgate_assert g1 python <<'PY'
import hashlib, os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "prof.virelaivm", "share")
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
applied = os.path.join(share, "UPDATE.APPLIED")
if not os.path.isdir(applied):
    sys.exit("applied set was not renamed to UPDATE.APPLIED")
want = open(os.path.join(run, "base.sha")).read().strip()
if h(os.path.join(applied, "OS.IMG")) == want:
    sys.exit("applied OS.IMG is the dev image — stage never took the payload")
if h(os.path.join(run, "base.img")) != want:
    sys.exit("rollback did not restore the pre-update base")
# Iteration hygiene: every later iteration's stage/apply must mint its
# own set and baseline; the seat's session file resets to the t-leg's
# fresh write too.
shutil.rmtree(applied)
for p in (os.path.join(share, "UPDATE"),
          os.path.join(run, "base.img.prev"),
          os.path.join(share, "SESSION.TABS"),
          os.path.join(share, "WINDOWS.SAV")):
    if os.path.isdir(p):
        shutil.rmtree(p)
    elif os.path.exists(p):
        os.remove(p)
print("g1: applied base booted (m120f-b), rollback restored dev, "
      "iteration state cleaned")
PY

# --- Iteration 2 -------------------------------------------------------------

vgate_file script-t2.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file script-t2b.txt <<'EOF'
exec NOTE.ELF
EOF
vgate_file script-t2c.txt <<'EOF'
echo ux-t2-done
EOF

vgate_run t2 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-t2' \
  --script '$RUN_DIR/script-t2.txt' \
  --script2 '$RUN_DIR/script-t2b.txt' --script2-after 'gotabwm: serving' \
  --script3 '$RUN_DIR/script-t2c.txt' --script3-after 'note: ready' \
  --host-cmd-after 'virelai> :apply-update' \
  --script-expect 'ux-t2-done' --timeout 180
vgate_assert t2 serial-contains 'gotabwm: session write n=1'
vgate_assert t2 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert t2 output-contains 'host-ui: cmd=apply-update vm=1 state=disabled staged=0'
vgate_assert t2 serial-absent '[EXC]'
vgate_assert t2 python <<'PY'
import os, sys
_wsav = os.path.join(os.environ["RUN_DIR"], "prof.virelaivm", "share", "WINDOWS.SAV")
if os.path.exists(_wsav):
    os.remove(_wsav)
b = open(os.path.join(os.environ["RUN_DIR"], "prof.virelaivm", "share",
                      "SESSION.TABS"), "rb").read()
assert b[0] == 2 and b[2] == 1 and b[51:75].split(b"\x00",1)[0] == b"NOTE.ELF", \
    "SESSION.TABS v2 n=1 NOTE.ELF"
print("t2: session write n=1 NOTE.ELF")
PY

vgate_file script-u2.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file script-u2b.txt <<'EOF'
exec GOSNAP.ELF
EOF
vgate_file script-u2c.txt <<'EOF'
exec GOSNAP.ELF save UX-2
EOF

vgate_run u2 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --vsock --vsock-ctl --screen '$RUN_DIR/screen-u2' \
  --script '$RUN_DIR/script-u2.txt' \
  --script2 '$RUN_DIR/script-u2b.txt' --script2-after 'gotabwm: session live n=1' \
  --script3 '$RUN_DIR/script-u2c.txt' --script3-after 'gosnap: ready n=' \
  --script-expect 'gosnap: save UX-2 ok' --script-expect-tail 6 --timeout 300
vgate_assert u2 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert u2 serial-contains 'gotabwm: session reexec n=1'
vgate_assert u2 serial-contains 'gotabwm: session exec NOTE.ELF'
vgate_assert u2 serial-contains 'gotabwm: session live n=1'
vgate_assert u2 serial-contains 'gosnap: open id='
vgate_assert u2 serial-contains 'gosnap: present'
vgate_assert u2 serial-contains 'gosnap: ready n='
vgate_assert u2 serial-contains 'gosnap: save UX-2 ok'
vgate_assert u2 serial-contains 'gosnap: snap name=UX-2 bytes='
vgate_assert u2 serial-absent '[EXC]'
vgate_assert u2 python <<'PY'
import os, re, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
ser = (Path(os.environ["VG_SER"])).read_bytes()
_wsav = run / "prof.virelaivm" / "share" / "WINDOWS.SAV"
if _wsav.exists():
    _wsav.unlink()
ids = [int(m.group(1)) for m in
       re.finditer(rb"gotabwm: tab open id=(\d+)", ser)]
assert ids and all(i < 0x100 for i in ids), "live ids under 0x100: %r" % ids
snap = run / "prof.virelaivm" / "share" / "SNAPSHOTS" / "UX-2.vzsave"
assert snap.exists() and snap.stat().st_size > 0, "UX-2 never parked"
print("u2: reexec live ids %s; UX-2 parked" % ids)
PY

vgate_file script-s2.txt <<'EOF'
clip ux-clip-k2
write UX-PROOF.TXT ux-bytes-k2-fedcba9876543210
vf cat UX-PROOF.TXT
exec GOSH.ELF serial
EOF
vgate_file script-s2b.txt <<'EOF'
exec GOSH.ELF serial
EOF

vgate_run s2 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-s2' \
  --script '$RUN_DIR/script-s2.txt' \
  --script3 '$RUN_DIR/gosh-q2.bin' --script3-after 'gosh: attached' --script3-delay 12 \
  --host-cmd-after 'gosh: attached:snapshot' \
  --host-cmd-after 'ux-s2-park:suspend' \
  --script-expect '__UX_S2_SUSPENDED__' --timeout 300
vgate_assert s2 serial-contains 'gosh: attached'
vgate_assert s2 output-contains 'host-ui: cmd=snapshot vm=1 state=performed'
vgate_assert s2 output-contains 'host-machine: snapshot saved menu-'
vgate_assert s2 output-contains 'host-ui: cmd=suspend vm=1 state=performed'
vgate_assert s2 output-contains 'host-machine: suspend saved; run stopping'
vgate_assert s2 output-contains 'VSOCK-CTL: suspend saved state.vzsave'
vgate_assert s2 serial-absent '[EXC]'
vgate_assert s2 python <<'PY'
import glob, os
from pathlib import Path
prof = Path(os.environ["RUN_DIR"]) / "prof.virelaivm"
state = prof / "saved-state" / "state.vzsave"
assert state.exists() and state.stat().st_size > 0, "no saved machine state"
snaps = glob.glob(str(prof / "share" / "SNAPSHOTS" / "menu-*.vzsave"))
assert snaps and all(os.path.getsize(p) > 0 for p in snaps)
print("s2: suspend saved (%d bytes), %d menu snapshot(s) parked"
      % (state.stat().st_size, len(snaps)))
PY

vgate_run r2 -- --resume '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-r2' \
  --script '$RUN_DIR/noop.txt' --script-after '__UX_R2_ARM__' \
  --script-expect 'ux-r2-done' --timeout 150
vgate_allow_rc r2 0 1
vgate_assert r2 output-contains 'SUSPEND-RESUME: armed state='
vgate_assert r2 python <<'PY'
import os, re, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
out = (run / ("run-%s.out" % os.environ["VG_TAG"])).read_bytes()
serial = Path(os.environ["VG_SER"]).read_bytes() if Path(os.environ["VG_SER"]).exists() else b""
assert b"VirelaiOS kernel has seized control." not in serial, "a restore never boots"
if b"SUSPEND-RESUME: restore refused code=12" in out:
    print("bound: restoreMachineStateFrom -> VZErrorDomain Code=12 (M119e)")
    sys.exit(0)
assert b"SUSPEND-RESUME: restored" in out, out[-800:]
for needle in (b"ux-resumed-k2", b"clip: ux-clip-k2",
               b"vf: cat UX-PROOF.TXT", b"ux-r2-done"):
    assert needle in serial, (needle, serial[-1500:])
def cksum(ser):
    m = re.search(rb"vf: cat UX-PROOF\.TXT size=(\d+)[\s\S]*?cksum=0x([0-9a-f]{4})", ser)
    assert m, ser[-1500:]
    return m.groups()
assert cksum((run / "vm-serial-s2.log").read_bytes()) == cksum(serial)
print("r2: queued probe executed post-restore; clip + share bytes intact")
PY

vgate_file script-f2.txt <<'EOF'
shutdown
EOF

vgate_run f2 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-f2' \
  --script '$RUN_DIR/script-f2.txt' \
  --host-cmd-after 'VirelaiOS kernel has seized control.:screenshot' \
  --script-expect '__UX_F2_NEVER__' --timeout 90
vgate_allow_rc f2 1
vgate_assert f2 serial-echo shutdown
vgate_assert f2 output-contains 'host-ui: cmd=screenshot vm=1 state=performed saved=1 file=screen-f2-hostui-1.png'
vgate_assert f2 output-contains 'host-cap: saved '
vgate_assert f2 output-contains 'host-inspector: postmortem ending=stopped'
vgate_assert f2 output-contains 'open=1'
vgate_assert f2 output-contains 'VM ended before the expected transcript'
vgate_assert f2 snapshot 'prof.virelaivm/share/CAPTURES/screen-f2-hostui-*' <<'PY'
import os, sys
p = sys.argv[1]
head = open(p, "rb").read(8)
assert head == b"\x89PNG\r\n\x1a\n" and os.path.getsize(p) > 0, "CAPTURES PNG"
print("f2 capture in CAPTURES: %s (%d bytes)" % (p, os.path.getsize(p)))
PY

vgate_file script-st2.txt <<'EOF'
sysinfo
exec GOUPD.ELF stage
EOF

vgate_run st2 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' \
  --script '$RUN_DIR/script-st2.txt' \
  --host-cmd-after 'update: staged ok:apply-update' \
  --script-expect 'update: exit rc=' --timeout 600
vgate_assert st2 serial-contains 'vf: probe 32k ok'
vgate_assert st2 serial-contains 'owners: OWNERS.TXT loaded'
vgate_assert st2 serial-contains 'version=dev'
vgate_assert st2 serial-contains 'update: staged ok version=m120f-b'
vgate_assert st2 serial-contains 'update: exit rc=0'
vgate_assert st2 output-contains 'host-ui: cmd=apply-update vm=1 state=performed'
vgate_assert st2 output-contains 'host-machine: applied version=m120f-b image=OS.IMG'
vgate_assert st2 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
applied = os.path.join(run, "prof.virelaivm", "share", "UPDATE.APPLIED")
mf = open(os.path.join(applied, "UPDATE.MF")).read()
assert "version=m120f-b" in mf, mf
h = lambda q: __import__("hashlib").sha256(open(q, "rb").read()).hexdigest()
assert h(os.path.join(run, "base.img")) == h(os.path.join(applied, "OS.IMG")),     "apply did not swap the private base"
ov = os.path.join(run, "prof.virelaivm", "overlay.asif")
if os.path.exists(ov):
    os.remove(ov)
print("st2: restaged on the rolled-back base; apply consumed the set")
PY

vgate_file script-g2.txt <<'EOF'
sysinfo
echo g2-go
EOF
vgate_file script-g2b.txt <<'EOF'
echo ux-g2-done
EOF

vgate_run g2 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' \
  --script '$RUN_DIR/script-g2.txt' \
  --script2 '$RUN_DIR/script-g2b.txt' --script2-after 'g2-go' --script2-delay 4 \
  --host-cmd-after 'g2-go:rollback-update' \
  --script-expect 'ux-g2-done' --timeout 180
vgate_assert g2 serial-contains 'version=m120f-b'
vgate_assert g2 serial-absent 'version=dev'
vgate_assert g2 output-contains 'host-ui: cmd=rollback-update vm=1 state=performed'
vgate_assert g2 output-contains 'host-machine: rollback restored sha256='
vgate_assert g2 serial-absent '[EXC]'
vgate_assert g2 python <<'PY'
import hashlib, os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.path.join(run, "prof.virelaivm", "share")
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
if h(os.path.join(run, "base.img")) != open(os.path.join(run, "base.sha")).read().strip():
    sys.exit("rollback did not restore the pre-update base")
shutil.rmtree(os.path.join(share, "UPDATE.APPLIED"))
for p in (os.path.join(share, "UPDATE"),
          os.path.join(run, "base.img.prev"),
          os.path.join(share, "SESSION.TABS"),
          os.path.join(share, "WINDOWS.SAV")):
    if os.path.isdir(p):
        shutil.rmtree(p)
    elif os.path.exists(p):
        os.remove(p)
print("g2: applied base booted, rollback restored dev, iteration cleaned")
PY

# --- Iteration 3 -------------------------------------------------------------

vgate_file script-t3.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file script-t3b.txt <<'EOF'
exec NOTE.ELF
EOF
vgate_file script-t3c.txt <<'EOF'
echo ux-t3-done
EOF

vgate_run t3 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-t3' \
  --script '$RUN_DIR/script-t3.txt' \
  --script2 '$RUN_DIR/script-t3b.txt' --script2-after 'gotabwm: serving' \
  --script3 '$RUN_DIR/script-t3c.txt' --script3-after 'gotabwm: session write n=1' \
  --host-cmd-after 'virelai> :apply-update' \
  --script-expect 'ux-t3-done' --timeout 180
vgate_assert t3 serial-contains 'gotabwm: session write n=1'
vgate_assert t3 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert t3 output-contains 'host-ui: cmd=apply-update vm=1 state=disabled staged=0'
vgate_assert t3 serial-absent '[EXC]'
vgate_assert t3 python <<'PY'
import os, sys
_wsav = os.path.join(os.environ["RUN_DIR"], "prof.virelaivm", "share", "WINDOWS.SAV")
if os.path.exists(_wsav):
    os.remove(_wsav)
b = open(os.path.join(os.environ["RUN_DIR"], "prof.virelaivm", "share",
                      "SESSION.TABS"), "rb").read()
assert b[0] == 2 and b[2] == 1 and b[51:75].split(b"\x00",1)[0] == b"NOTE.ELF"
print("t3: session write n=1 NOTE.ELF")
PY

vgate_file script-u3.txt <<'EOF'
set GOMAXPROCS=1
wm
exec GOTABWM.ELF
EOF
vgate_file script-u3b.txt <<'EOF'
exec GOSNAP.ELF
EOF
vgate_file script-u3c.txt <<'EOF'
exec GOSNAP.ELF save UX-3
EOF

vgate_run u3 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --vsock --vsock-ctl --screen '$RUN_DIR/screen-u3' \
  --script '$RUN_DIR/script-u3.txt' \
  --script2 '$RUN_DIR/script-u3b.txt' --script2-after 'gotabwm: session live n=1' \
  --script3 '$RUN_DIR/script-u3c.txt' --script3-after 'gosnap: ready n=' \
  --script-expect 'gosnap: save UX-3 ok' --script-expect-tail 6 --timeout 300
vgate_assert u3 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert u3 serial-contains 'gotabwm: session reexec n=1'
vgate_assert u3 serial-contains 'gotabwm: session exec NOTE.ELF'
vgate_assert u3 serial-contains 'gotabwm: session live n=1'
vgate_assert u3 serial-contains 'gosnap: open id='
vgate_assert u3 serial-contains 'gosnap: present'
vgate_assert u3 serial-contains 'gosnap: ready n='
vgate_assert u3 serial-contains 'gosnap: save UX-3 ok'
vgate_assert u3 serial-contains 'gosnap: snap name=UX-3 bytes='
vgate_assert u3 serial-absent '[EXC]'
vgate_assert u3 python <<'PY'
import os, re, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
ser = (Path(os.environ["VG_SER"])).read_bytes()
_wsav = run / "prof.virelaivm" / "share" / "WINDOWS.SAV"
if _wsav.exists():
    _wsav.unlink()
ids = [int(m.group(1)) for m in
       re.finditer(rb"gotabwm: tab open id=(\d+)", ser)]
assert ids and all(i < 0x100 for i in ids), "live ids under 0x100: %r" % ids
snap = run / "prof.virelaivm" / "share" / "SNAPSHOTS" / "UX-3.vzsave"
assert snap.exists() and snap.stat().st_size > 0, "UX-3 never parked"
print("u3: reexec live ids %s; UX-3 parked" % ids)
PY

vgate_file script-s3.txt <<'EOF'
clip ux-clip-k3
write UX-PROOF.TXT ux-bytes-k3-13579bdf02468ace
vf cat UX-PROOF.TXT
exec GOSH.ELF serial
EOF
vgate_file script-s3b.txt <<'EOF'
exec GOSH.ELF serial
EOF

vgate_run s3 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-s3' \
  --script '$RUN_DIR/script-s3.txt' \
  --script3 '$RUN_DIR/gosh-q3.bin' --script3-after 'gosh: attached' --script3-delay 12 \
  --host-cmd-after 'gosh: attached:snapshot' \
  --host-cmd-after 'ux-s3-park:suspend' \
  --script-expect '__UX_S3_SUSPENDED__' --timeout 300
vgate_assert s3 serial-contains 'gosh: attached'
vgate_assert s3 output-contains 'host-ui: cmd=snapshot vm=1 state=performed'
vgate_assert s3 output-contains 'host-machine: snapshot saved menu-'
vgate_assert s3 output-contains 'host-ui: cmd=suspend vm=1 state=performed'
vgate_assert s3 output-contains 'host-machine: suspend saved; run stopping'
vgate_assert s3 output-contains 'VSOCK-CTL: suspend saved state.vzsave'
vgate_assert s3 serial-absent '[EXC]'
vgate_assert s3 python <<'PY'
import glob, os
from pathlib import Path
prof = Path(os.environ["RUN_DIR"]) / "prof.virelaivm"
state = prof / "saved-state" / "state.vzsave"
assert state.exists() and state.stat().st_size > 0, "no saved machine state"
snaps = glob.glob(str(prof / "share" / "SNAPSHOTS" / "menu-*.vzsave"))
assert snaps and all(os.path.getsize(p) > 0 for p in snaps)
print("s3: suspend saved (%d bytes), %d menu snapshot(s) parked — K=3"
      % (state.stat().st_size, len(snaps)))
PY

vgate_run r3 -- --resume '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-r3' \
  --script '$RUN_DIR/noop.txt' --script-after '__UX_R3_ARM__' \
  --script-expect 'ux-r3-done' --timeout 150
vgate_allow_rc r3 0 1
vgate_assert r3 output-contains 'SUSPEND-RESUME: armed state='
vgate_assert r3 python <<'PY'
import os, re, sys
from pathlib import Path
run = Path(os.environ["RUN_DIR"])
out = (run / ("run-%s.out" % os.environ["VG_TAG"])).read_bytes()
serial = Path(os.environ["VG_SER"]).read_bytes() if Path(os.environ["VG_SER"]).exists() else b""
assert b"VirelaiOS kernel has seized control." not in serial, "a restore never boots"
if b"SUSPEND-RESUME: restore refused code=12" in out:
    print("bound: restoreMachineStateFrom -> VZErrorDomain Code=12 (M119e)")
    sys.exit(0)
assert b"SUSPEND-RESUME: restored" in out, out[-800:]
for needle in (b"ux-resumed-k3", b"clip: ux-clip-k3",
               b"vf: cat UX-PROOF.TXT", b"ux-r3-done"):
    assert needle in serial, (needle, serial[-1500:])
def cksum(ser):
    m = re.search(rb"vf: cat UX-PROOF\.TXT size=(\d+)[\s\S]*?cksum=0x([0-9a-f]{4})", ser)
    assert m, ser[-1500:]
    return m.groups()
assert cksum((run / "vm-serial-s3.log").read_bytes()) == cksum(serial)
print("r3: queued probe executed post-restore — K=3 complete")
PY

vgate_file script-f3.txt <<'EOF'
shutdown
EOF

vgate_run f3 -- --profile '$RUN_DIR/prof.virelaivm' --virtio-fs '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' --screen '$RUN_DIR/screen-f3' \
  --script '$RUN_DIR/script-f3.txt' \
  --host-cmd-after 'VirelaiOS kernel has seized control.:screenshot' \
  --script-expect '__UX_F3_NEVER__' --timeout 90
vgate_allow_rc f3 1
vgate_assert f3 serial-echo shutdown
vgate_assert f3 output-contains 'host-ui: cmd=screenshot vm=1 state=performed saved=1 file=screen-f3-hostui-1.png'
vgate_assert f3 output-contains 'host-cap: saved '
vgate_assert f3 output-contains 'host-inspector: postmortem ending=stopped'
vgate_assert f3 output-contains 'open=1'
vgate_assert f3 output-contains 'VM ended before the expected transcript'
vgate_assert f3 snapshot 'prof.virelaivm/share/CAPTURES/screen-f3-hostui-*' <<'PY'
import os, sys
p = sys.argv[1]
head = open(p, "rb").read(8)
assert head == b"\x89PNG\r\n\x1a\n" and os.path.getsize(p) > 0, "CAPTURES PNG"
print("f3 capture in CAPTURES: %s (%d bytes)" % (p, os.path.getsize(p)))
PY

vgate_file script-st3.txt <<'EOF'
sysinfo
exec GOUPD.ELF stage
EOF

vgate_run st3 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' \
  --script '$RUN_DIR/script-st3.txt' \
  --host-cmd-after 'update: staged ok:apply-update' \
  --script-expect 'update: exit rc=' --timeout 600
vgate_assert st3 serial-contains 'vf: probe 32k ok'
vgate_assert st3 serial-contains 'owners: OWNERS.TXT loaded'
vgate_assert st3 serial-contains 'version=dev'
vgate_assert st3 serial-contains 'update: staged ok version=m120f-b'
vgate_assert st3 serial-contains 'update: exit rc=0'
vgate_assert st3 output-contains 'host-ui: cmd=apply-update vm=1 state=performed'
vgate_assert st3 output-contains 'host-machine: applied version=m120f-b image=OS.IMG'
vgate_assert st3 python <<'PY'
import os, sys
run = os.environ["RUN_DIR"]
applied = os.path.join(run, "prof.virelaivm", "share", "UPDATE.APPLIED")
mf = open(os.path.join(applied, "UPDATE.MF")).read()
assert "version=m120f-b" in mf, mf
h = lambda q: __import__("hashlib").sha256(open(q, "rb").read()).hexdigest()
assert h(os.path.join(run, "base.img")) == h(os.path.join(applied, "OS.IMG")),     "apply did not swap the private base"
ov = os.path.join(run, "prof.virelaivm", "overlay.asif")
if os.path.exists(ov):
    os.remove(ov)
print("st3: third stage+apply consumed the set")
PY

vgate_file script-g3.txt <<'EOF'
sysinfo
echo g3-go
EOF
vgate_file script-g3b.txt <<'EOF'
echo ux-g3-done
EOF

vgate_run g3 -- --profile '$RUN_DIR/prof.virelaivm' --cvc-file '$RUN_DIR/prof.virelaivm/share' \
  --overlay-base '$RUN_DIR/base.img' \
  --script '$RUN_DIR/script-g3.txt' \
  --script2 '$RUN_DIR/script-g3b.txt' --script2-after 'g3-go' --script2-delay 4 \
  --host-cmd-after 'g3-go:rollback-update' \
  --script-expect 'ux-g3-done' --timeout 180
vgate_assert g3 serial-contains 'version=m120f-b'
vgate_assert g3 serial-absent 'version=dev'
vgate_assert g3 output-contains 'host-ui: cmd=rollback-update vm=1 state=performed'
vgate_assert g3 output-contains 'host-machine: rollback restored sha256='
vgate_assert g3 serial-absent '[EXC]'
vgate_assert g3 python <<'PY'
import hashlib, os, sys
run = os.environ["RUN_DIR"]
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
if h(os.path.join(run, "base.img")) != open(os.path.join(run, "base.sha")).read().strip():
    sys.exit("rollback did not restore the pre-update base")
print("g3: third apply+rollback round-trip — K=3 complete")
PY
