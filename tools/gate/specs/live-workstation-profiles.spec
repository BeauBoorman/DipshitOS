# live-workstation-profiles.spec -- M128e (#2609, index #2556): the
# workstation acceptance journey on the real profile machinery, K=3.
# One session-minted .virelaivm per iteration carries the whole arc:
# mint -> settings -> clone -> reset overlay -> share/ survives ->
# new CPU/RAM live on next boot.
#
# The mint is the SESSION'S OWN mint -- tools/session.sh
# --provision-only (the path a human `just session` runs), observed
# through its `profile: created` + provisioning receipt: manifest,
# config, the four SECRETS.TXT rows + OWNERS.TXT, the
# config.updatePubkey pin, and a formatted vlfs.img all land through
# session.sh, never a gate-local reconstruction (the M120a precedent).
#
# The settings/clone/reset legs dispatch through the HostCommand bus:
# --host-cmd-after fires the ⌘, verb and the two Machine-menu verbs
# down the identical seam the session window's menus use; every
# dispatch writes one `host-ui:` receipt on runner stdout. A scripted
# headless run never wires the profiles model's vmRunning/confirm
# seams (HostApplication owns them under --host-session), so the
# destructive verbs pass their confirm gate the same way they would
# on a stopped session.
#
# The panel's field draft is UI-only -- no bus verb types into it --
# so the persisted half of a settings edit lands between runs: the
# vK assert hook writes config.json in the shape
# HostSettingsModel.save() emits (pretty-printed sorted-key JSON,
# unedited members like updatePubkey carried through). The cK
# --profile-init then re-reads the bundle through VMProfile.load --
# the panel's own load path -- and nK's boot line plus the guest's
# `smp`/`sysinfo` prove the new shape live.
#
# PLATFORM ENVELOPE (observed on this host, 2026-10-19): the guest
# kernel seizes a guest RAM allotment of at most 256 MiB -- direct
# --profile boots at memoryMiB 288/320/384/512 emit ZERO serial bytes
# (the VM starts; the kernel never reaches its first UART line),
# while 160/192/224/256 boot normally. SMP bring-up tops out at
# smp.max_cores = 4. The runner accepts cpus 1...8 and memoryMiB >0;
# the guest envelope is narrower, so the journey edits WITHIN it --
# cpus 2->4/3 and memoryMiB 256->192/224/160 -- and the >256 MiB leg
# is named for a kernel card (the ceiling is in the guest, not this
# host -- it is not a reference-host gap).
#
# Per iteration k (1..3), four legs on $RUN_DIR/ws<k>.virelaivm:
#   m<k> -- --profile-init loads the minted bundle at its compiled
#           defaults (cpus=2 memoryMiB=256): the mint is a leg, not a
#           fixture.
#   v<k> -- a real boot at the minted shape. The guest writes
#           WS-KEEP.TXT to the share and WS-DISK.TXT to /disk, then
#           three verb dispatches land: `settings` opens the armed
#           panel (open=1), `profile-clone` mints ws<k>-copy carrying
#           config + a recursive share/ copy -- the KEEP file rides
#           it, because the trigger anchors on the guest's own
#           `vf: cat` read-back, not a script echo -- and
#           `profile-reset-overlay` unlinks the live overlay.asif
#           mid-run. The post-run hook verifies the clone is a real
#           sibling (fresh identity; no overlay/vlfs/efi-vars/
#           machine-id), that the armed share and vlfs.img are
#           untouched, that overlay.asif is gone -- and then writes
#           the Save (cpus=<K> memoryMiB=<M>).
#   c<k> -- --profile-init re-loads the edited bundle: the persisted
#           shape reads back through the profile's own validation.
#   n<k> -- next boot: the runner's `memory:/cpus:` line, the guest's
#           `smp` report, and grown `sysinfo` usable memory prove the
#           new CPU/RAM are live on a RE-MINTED overlay; `vf cat`
#           re-reads both fixtures with the same cksums -- share/ and
#           vlfs.img survive the reset, the reboot, and the shape
#           change.
#
# exec-order: intentional -- no run launches a program; every script
# is monitor verbs + echoes, so the guard's two shapes never arise.
# The reset-overlay verb deletes a file the running VM holds open --
# the designed safety-net posture (the VM's writes land in the dead
# inode; the next boot re-mints over the read-only base).
#
# HOST PREREQUISITES: none beyond the gate preamble -- session.sh
# --provision-only builds mkfs.vlfs from stock host go; the Go seat
# is skipped (VIRELAI_SESSION_NO_GOTABWM=1).

vgate_name live-workstation-profiles "M128e #2609: workstation journey -- mint -> settings -> clone -> reset overlay -> share/ survives -> new CPU/RAM live, K=3"
vgate_share none
vgate_runner_flags -Xswiftc -DSPIKE

# Mint all three workstations through the session's own provisioning --
# each "profile: created" receipt is the mint leg's observed evidence.
vgate_setup_python <<'PY'
import json, os, subprocess, sys
run = os.environ["RUN_DIR"]
for k in (1, 2, 3):
    prof = os.path.join(run, "ws%d.virelaivm" % k)
    env = dict(os.environ)
    env["VIRELAI_SESSION_PROFILE"] = prof
    env["VIRELAI_SESSION_SKIP_BUILD"] = "1"
    env["VIRELAI_SESSION_NO_GOTABWM"] = "1"
    r = subprocess.run(["bash", "tools/session.sh", "--provision-only"],
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        sys.exit("session.sh --provision-only ws%d rc=%d: %s%s"
                 % (k, r.returncode, r.stdout[-1500:], r.stderr[-1500:]))
    for needle in ("profile: created", "session: provisioning complete"):
        if needle not in r.stdout:
            sys.exit("ws%d: provisioning output lacks %r: %s"
                     % (k, needle, r.stdout[-1500:]))
    man = json.load(open(os.path.join(prof, "manifest.json")))
    if man.get("format") != "virelaivm/1" or man.get("name") != "ws%d" % k:
        sys.exit("ws%d manifest bad: %r" % (k, man))
    cfg = json.load(open(os.path.join(prof, "config.json")))
    if cfg.get("cpus") != 2 or cfg.get("memoryMiB") != 256:
        sys.exit("ws%d not at compiled defaults: %r" % (k, cfg))
    if cfg.get("baseImage") != os.path.abspath("artifacts/disk.img"):
        sys.exit("ws%d baseImage not pinned absolute: %r"
                 % (k, cfg.get("baseImage")))
    for member in ("share", "dataDisk"):
        if not cfg.get("devices", {}).get(member):
            sys.exit("ws%d devices.%s not armed" % (k, member))
    if not cfg.get("updatePubkey"):
        sys.exit("ws%d missing the os-update pubkey pin")
    share = os.path.join(prof, "share")
    for name in ("SECRETS.TXT", "OWNERS.TXT", "APPS.TXT"):
        if not os.path.isfile(os.path.join(share, name)):
            sys.exit("ws%d share missing %s" % (k, name))
    mkfs = os.path.join(".build", "go", "mkfs.vlfs")
    if not os.path.exists(mkfs):
        sys.exit("session.sh did not build mkfs.vlfs")
    c = subprocess.run([mkfs, "--check", os.path.join(prof, "vlfs.img")],
                       capture_output=True, text=True)
    if c.returncode != 0 or "check: clean" not in c.stdout:
        sys.exit("ws%d vlfs.img not a clean volume: %s%s"
                 % (k, c.stdout, c.stderr))
print("setup: session.sh minted + provisioned ws1/ws2/ws3 "
      "(profile: created x3, credentials + pubkey pin, clean vlfs)")
PY

# === Iteration 1 =====================================================

vgate_file script-v1.txt <<'EOF'
write WS-KEEP.TXT ws-keep-bytes-k1
echo ws-settings-k1
vf cat WS-KEEP.TXT
write /disk/WS-DISK.TXT ws-disk-bytes-k1
vf cat /disk/WS-DISK.TXT
smp
sysinfo
echo ws-reset-k1
echo ws-done-k1
EOF

vgate_run m1 -- --profile '$RUN_DIR/ws1.virelaivm' --profile-init --timeout 60
vgate_assert m1 output-contains 'profile: loaded'
vgate_assert m1 output-contains 'profile: identity=org.virelaios.vm.ws1 cpus=2 memoryMiB=256'

vgate_run v1 -- --profile '$RUN_DIR/ws1.virelaivm' \
    --script '$RUN_DIR/script-v1.txt' \
    --host-cmd-after 'ws-settings-k1:settings' \
    --host-cmd-after 'vf: cat WS-KEEP.TXT:profile-clone' \
    --host-cmd-after 'ws-reset-k1:profile-reset-overlay' \
    --script-expect 'ws-done-k1' --timeout 240
vgate_assert v1 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert v1 serial-contains 'vlfs: mounted /disk'
vgate_assert v1 serial-contains 'write: ok (persisted '
vgate_assert v1 serial-contains 'vf: cat WS-KEEP.TXT size='
vgate_assert v1 serial-contains 'vf: cat ok bytes='
vgate_assert v1 serial-contains 'write: ok (journaled '
vgate_assert v1 serial-contains 'vf: cat disk:WS-DISK.TXT size='
vgate_assert v1 serial-contains 'smp: cores=2 online=2'
vgate_assert v1 output-contains 'host-ui: cmd=settings vm=1 state=performed open=1'
vgate_assert v1 output-contains 'host-ui: cmd=profile-clone vm=1 state=performed armed=ws1 clone=ws1-copy'
vgate_assert v1 output-contains 'host-profiles: cloned'
vgate_assert v1 output-contains 'host-ui: cmd=profile-reset-overlay vm=1 state=performed armed=ws1 overlay=reset'
vgate_assert v1 output-contains 'host-profiles: overlay reset'
vgate_assert v1 serial-absent '[EXC]'
vgate_assert v1 python <<'PY'
import json, os, sys
run = os.environ["RUN_DIR"]
prof = os.path.join(run, "ws1.virelaivm")
clone = os.path.join(run, "ws1-copy.virelaivm")

kpath = os.path.join(prof, "share", "WS-KEEP.TXT")
if not os.path.isfile(kpath) or "ws-keep-bytes-k1" not in open(kpath).read():
    sys.exit("armed share lost WS-KEEP.TXT")

for member in ("manifest.json", "config.json"):
    if not os.path.isfile(os.path.join(clone, member)):
        sys.exit("clone missing " + member)
aman = json.load(open(os.path.join(prof, "manifest.json")))
cman = json.load(open(os.path.join(clone, "manifest.json")))
if cman.get("name") != "ws1-copy":
    sys.exit("clone named %r" % cman.get("name"))
if cman.get("identity") == aman.get("identity"):
    sys.exit("clone reused the armed bundle's identity")
ccfg = json.load(open(os.path.join(clone, "config.json")))
acfg = json.load(open(os.path.join(prof, "config.json")))
if ccfg != acfg:
    sys.exit("clone config diverged: %r vs %r" % (ccfg, acfg))
for rel in ("WS-KEEP.TXT", "SECRETS.TXT", "OWNERS.TXT", "APPS.TXT"):
    a = os.path.join(prof, "share", rel)
    c = os.path.join(clone, "share", rel)
    if not os.path.isfile(c) or open(a, "rb").read() != open(c, "rb").read():
        sys.exit("clone share member %r missing or divergent" % rel)
for member in ("overlay.asif", "vlfs.img", "efi-vars.bin", "machine-id.bin"):
    if os.path.exists(os.path.join(clone, member)):
        sys.exit("clone carries a runtime member: " + member)
if os.path.exists(os.path.join(prof, "overlay.asif")):
    sys.exit("profile-reset-overlay left overlay.asif in the armed bundle")
if not os.path.isfile(os.path.join(prof, "vlfs.img")):
    sys.exit("reset took vlfs.img with it")

# The Save: the persisted half of the settings edit, written in the
# shape HostSettingsModel.save() emits -- unedited members carry.
cfg_path = os.path.join(prof, "config.json")
cfg = json.load(open(cfg_path))
pub = cfg.get("updatePubkey")
cfg["cpus"] = 4
cfg["memoryMiB"] = 192
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, sort_keys=True)
    f.write("\n")
cfg2 = json.load(open(cfg_path))
if cfg2.get("cpus") != 4 or cfg2.get("memoryMiB") != 192 \
        or cfg2.get("updatePubkey") != pub:
    sys.exit("the settings save did not persist")
print("v1: clone verified (config + share/, fresh identity); overlay "
      "reset; save persisted cpus=4 memoryMiB=192")
PY

vgate_run c1 -- --profile '$RUN_DIR/ws1.virelaivm' --profile-init --timeout 60
vgate_assert c1 output-contains 'profile: loaded'
vgate_assert c1 output-contains 'cpus=4 memoryMiB=192'

vgate_file script-n1.txt <<'EOF'
smp
sysinfo
vf cat WS-KEEP.TXT
vf cat /disk/WS-DISK.TXT
echo ws-live-k1
EOF

vgate_run n1 -- --profile '$RUN_DIR/ws1.virelaivm' \
    --script '$RUN_DIR/script-n1.txt' \
    --script-expect 'ws-live-k1' --timeout 240
vgate_assert n1 output-contains '  memory: 192 MiB, cpus: 4'
vgate_assert n1 output-contains 'persistent ASIF overlay'
vgate_assert n1 serial-contains 'smp: cores=4 online=4'
vgate_assert n1 serial-contains 'vlfs: mounted /disk'
vgate_assert n1 serial-contains 'vf: cat WS-KEEP.TXT size='
vgate_assert n1 serial-contains 'vf: cat disk:WS-DISK.TXT size='
vgate_assert n1 serial-absent '[EXC]'
vgate_assert n1 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
prof = os.path.join(run, "ws1.virelaivm")
if not os.path.isfile(os.path.join(prof, "overlay.asif")):
    sys.exit("n1: no overlay.asif -- the attach point did not re-mint")
nser = open(os.environ["VG_SER"], errors="replace").read()
vser = open(os.path.join(run, "vm-serial-v1.log"), errors="replace").read()
def cksum(ser, marker):
    i = ser.find(marker)
    if i < 0:
        sys.exit("no %r in serial" % marker)
    m = re.search(r"cksum=0x([0-9a-f]{4})", ser[i:])
    if not m:
        sys.exit("no cksum after %r" % marker)
    return m.group(1)
for marker in ("vf: cat WS-KEEP.TXT", "vf: cat disk:WS-DISK.TXT"):
    if cksum(vser, marker) != cksum(nser, marker):
        sys.exit("%r cksum changed across reset+reboot" % marker)
def usable(ser):
    m = re.search(r"usable=0x([0-9a-f]+)", ser)
    if not m:
        sys.exit("no sysinfo usable= line")
    return int(m.group(1), 16)
uv, un = usable(vser), usable(nser)
if un >= uv:
    sys.exit("usable RAM did not track the edit: v1=%#x n1=%#x" % (uv, un))
if un >= 192 * 1024 * 1024:
    sys.exit("n1 usable %#x above the 192 MiB allotment" % un)
print("n1: overlay re-minted; KEEP/DISK cksums survive reset+reboot; "
      "usable %#x -> %#x" % (uv, un))
PY

# === Iteration 2 =====================================================

vgate_file script-v2.txt <<'EOF'
write WS-KEEP.TXT ws-keep-bytes-k2
echo ws-settings-k2
vf cat WS-KEEP.TXT
write /disk/WS-DISK.TXT ws-disk-bytes-k2
vf cat /disk/WS-DISK.TXT
smp
sysinfo
echo ws-reset-k2
echo ws-done-k2
EOF

vgate_run m2 -- --profile '$RUN_DIR/ws2.virelaivm' --profile-init --timeout 60
vgate_assert m2 output-contains 'profile: loaded'
vgate_assert m2 output-contains 'profile: identity=org.virelaios.vm.ws2 cpus=2 memoryMiB=256'

vgate_run v2 -- --profile '$RUN_DIR/ws2.virelaivm' \
    --script '$RUN_DIR/script-v2.txt' \
    --host-cmd-after 'ws-settings-k2:settings' \
    --host-cmd-after 'vf: cat WS-KEEP.TXT:profile-clone' \
    --host-cmd-after 'ws-reset-k2:profile-reset-overlay' \
    --script-expect 'ws-done-k2' --timeout 240
vgate_assert v2 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert v2 serial-contains 'vlfs: mounted /disk'
vgate_assert v2 serial-contains 'write: ok (persisted '
vgate_assert v2 serial-contains 'vf: cat WS-KEEP.TXT size='
vgate_assert v2 serial-contains 'vf: cat ok bytes='
vgate_assert v2 serial-contains 'write: ok (journaled '
vgate_assert v2 serial-contains 'vf: cat disk:WS-DISK.TXT size='
vgate_assert v2 serial-contains 'smp: cores=2 online=2'
vgate_assert v2 output-contains 'host-ui: cmd=settings vm=1 state=performed open=1'
vgate_assert v2 output-contains 'host-ui: cmd=profile-clone vm=1 state=performed armed=ws2 clone=ws2-copy'
vgate_assert v2 output-contains 'host-profiles: cloned'
vgate_assert v2 output-contains 'host-ui: cmd=profile-reset-overlay vm=1 state=performed armed=ws2 overlay=reset'
vgate_assert v2 output-contains 'host-profiles: overlay reset'
vgate_assert v2 serial-absent '[EXC]'
vgate_assert v2 python <<'PY'
import json, os, sys
run = os.environ["RUN_DIR"]
prof = os.path.join(run, "ws2.virelaivm")
clone = os.path.join(run, "ws2-copy.virelaivm")

kpath = os.path.join(prof, "share", "WS-KEEP.TXT")
if not os.path.isfile(kpath) or "ws-keep-bytes-k2" not in open(kpath).read():
    sys.exit("armed share lost WS-KEEP.TXT")

for member in ("manifest.json", "config.json"):
    if not os.path.isfile(os.path.join(clone, member)):
        sys.exit("clone missing " + member)
aman = json.load(open(os.path.join(prof, "manifest.json")))
cman = json.load(open(os.path.join(clone, "manifest.json")))
if cman.get("name") != "ws2-copy":
    sys.exit("clone named %r" % cman.get("name"))
if cman.get("identity") == aman.get("identity"):
    sys.exit("clone reused the armed bundle's identity")
ccfg = json.load(open(os.path.join(clone, "config.json")))
acfg = json.load(open(os.path.join(prof, "config.json")))
if ccfg != acfg:
    sys.exit("clone config diverged: %r vs %r" % (ccfg, acfg))
for rel in ("WS-KEEP.TXT", "SECRETS.TXT", "OWNERS.TXT", "APPS.TXT"):
    a = os.path.join(prof, "share", rel)
    c = os.path.join(clone, "share", rel)
    if not os.path.isfile(c) or open(a, "rb").read() != open(c, "rb").read():
        sys.exit("clone share member %r missing or divergent" % rel)
for member in ("overlay.asif", "vlfs.img", "efi-vars.bin", "machine-id.bin"):
    if os.path.exists(os.path.join(clone, member)):
        sys.exit("clone carries a runtime member: " + member)
if os.path.exists(os.path.join(prof, "overlay.asif")):
    sys.exit("profile-reset-overlay left overlay.asif in the armed bundle")
if not os.path.isfile(os.path.join(prof, "vlfs.img")):
    sys.exit("reset took vlfs.img with it")

cfg_path = os.path.join(prof, "config.json")
cfg = json.load(open(cfg_path))
pub = cfg.get("updatePubkey")
cfg["cpus"] = 3
cfg["memoryMiB"] = 224
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, sort_keys=True)
    f.write("\n")
cfg2 = json.load(open(cfg_path))
if cfg2.get("cpus") != 3 or cfg2.get("memoryMiB") != 224 \
        or cfg2.get("updatePubkey") != pub:
    sys.exit("the settings save did not persist")
print("v2: clone verified (config + share/, fresh identity); overlay "
      "reset; save persisted cpus=3 memoryMiB=224")
PY

vgate_run c2 -- --profile '$RUN_DIR/ws2.virelaivm' --profile-init --timeout 60
vgate_assert c2 output-contains 'profile: loaded'
vgate_assert c2 output-contains 'cpus=3 memoryMiB=224'

vgate_file script-n2.txt <<'EOF'
smp
sysinfo
vf cat WS-KEEP.TXT
vf cat /disk/WS-DISK.TXT
echo ws-live-k2
EOF

vgate_run n2 -- --profile '$RUN_DIR/ws2.virelaivm' \
    --script '$RUN_DIR/script-n2.txt' \
    --script-expect 'ws-live-k2' --timeout 240
vgate_assert n2 output-contains '  memory: 224 MiB, cpus: 3'
vgate_assert n2 output-contains 'persistent ASIF overlay'
vgate_assert n2 serial-contains 'smp: cores=3 online=3'
vgate_assert n2 serial-contains 'vlfs: mounted /disk'
vgate_assert n2 serial-contains 'vf: cat WS-KEEP.TXT size='
vgate_assert n2 serial-contains 'vf: cat disk:WS-DISK.TXT size='
vgate_assert n2 serial-absent '[EXC]'
vgate_assert n2 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
prof = os.path.join(run, "ws2.virelaivm")
if not os.path.isfile(os.path.join(prof, "overlay.asif")):
    sys.exit("n2: no overlay.asif -- the attach point did not re-mint")
nser = open(os.environ["VG_SER"], errors="replace").read()
vser = open(os.path.join(run, "vm-serial-v2.log"), errors="replace").read()
def cksum(ser, marker):
    i = ser.find(marker)
    if i < 0:
        sys.exit("no %r in serial" % marker)
    m = re.search(r"cksum=0x([0-9a-f]{4})", ser[i:])
    if not m:
        sys.exit("no cksum after %r" % marker)
    return m.group(1)
for marker in ("vf: cat WS-KEEP.TXT", "vf: cat disk:WS-DISK.TXT"):
    if cksum(vser, marker) != cksum(nser, marker):
        sys.exit("%r cksum changed across reset+reboot" % marker)
def usable(ser):
    m = re.search(r"usable=0x([0-9a-f]+)", ser)
    if not m:
        sys.exit("no sysinfo usable= line")
    return int(m.group(1), 16)
uv, un = usable(vser), usable(nser)
if un >= uv:
    sys.exit("usable RAM did not track the edit: v2=%#x n2=%#x" % (uv, un))
if un >= 224 * 1024 * 1024:
    sys.exit("n2 usable %#x above the 224 MiB allotment" % un)
print("n2: overlay re-minted; KEEP/DISK cksums survive reset+reboot; "
      "usable %#x -> %#x" % (uv, un))
PY

# === Iteration 3 =====================================================

vgate_file script-v3.txt <<'EOF'
write WS-KEEP.TXT ws-keep-bytes-k3
echo ws-settings-k3
vf cat WS-KEEP.TXT
write /disk/WS-DISK.TXT ws-disk-bytes-k3
vf cat /disk/WS-DISK.TXT
smp
sysinfo
echo ws-reset-k3
echo ws-done-k3
EOF

vgate_run m3 -- --profile '$RUN_DIR/ws3.virelaivm' --profile-init --timeout 60
vgate_assert m3 output-contains 'profile: loaded'
vgate_assert m3 output-contains 'profile: identity=org.virelaios.vm.ws3 cpus=2 memoryMiB=256'

vgate_run v3 -- --profile '$RUN_DIR/ws3.virelaivm' \
    --script '$RUN_DIR/script-v3.txt' \
    --host-cmd-after 'ws-settings-k3:settings' \
    --host-cmd-after 'vf: cat WS-KEEP.TXT:profile-clone' \
    --host-cmd-after 'ws-reset-k3:profile-reset-overlay' \
    --script-expect 'ws-done-k3' --timeout 240
vgate_assert v3 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert v3 serial-contains 'vlfs: mounted /disk'
vgate_assert v3 serial-contains 'write: ok (persisted '
vgate_assert v3 serial-contains 'vf: cat WS-KEEP.TXT size='
vgate_assert v3 serial-contains 'vf: cat ok bytes='
vgate_assert v3 serial-contains 'write: ok (journaled '
vgate_assert v3 serial-contains 'vf: cat disk:WS-DISK.TXT size='
vgate_assert v3 serial-contains 'smp: cores=2 online=2'
vgate_assert v3 output-contains 'host-ui: cmd=settings vm=1 state=performed open=1'
vgate_assert v3 output-contains 'host-ui: cmd=profile-clone vm=1 state=performed armed=ws3 clone=ws3-copy'
vgate_assert v3 output-contains 'host-profiles: cloned'
vgate_assert v3 output-contains 'host-ui: cmd=profile-reset-overlay vm=1 state=performed armed=ws3 overlay=reset'
vgate_assert v3 output-contains 'host-profiles: overlay reset'
vgate_assert v3 serial-absent '[EXC]'
vgate_assert v3 python <<'PY'
import json, os, sys
run = os.environ["RUN_DIR"]
prof = os.path.join(run, "ws3.virelaivm")
clone = os.path.join(run, "ws3-copy.virelaivm")

kpath = os.path.join(prof, "share", "WS-KEEP.TXT")
if not os.path.isfile(kpath) or "ws-keep-bytes-k3" not in open(kpath).read():
    sys.exit("armed share lost WS-KEEP.TXT")

for member in ("manifest.json", "config.json"):
    if not os.path.isfile(os.path.join(clone, member)):
        sys.exit("clone missing " + member)
aman = json.load(open(os.path.join(prof, "manifest.json")))
cman = json.load(open(os.path.join(clone, "manifest.json")))
if cman.get("name") != "ws3-copy":
    sys.exit("clone named %r" % cman.get("name"))
if cman.get("identity") == aman.get("identity"):
    sys.exit("clone reused the armed bundle's identity")
ccfg = json.load(open(os.path.join(clone, "config.json")))
acfg = json.load(open(os.path.join(prof, "config.json")))
if ccfg != acfg:
    sys.exit("clone config diverged: %r vs %r" % (ccfg, acfg))
for rel in ("WS-KEEP.TXT", "SECRETS.TXT", "OWNERS.TXT", "APPS.TXT"):
    a = os.path.join(prof, "share", rel)
    c = os.path.join(clone, "share", rel)
    if not os.path.isfile(c) or open(a, "rb").read() != open(c, "rb").read():
        sys.exit("clone share member %r missing or divergent" % rel)
for member in ("overlay.asif", "vlfs.img", "efi-vars.bin", "machine-id.bin"):
    if os.path.exists(os.path.join(clone, member)):
        sys.exit("clone carries a runtime member: " + member)
if os.path.exists(os.path.join(prof, "overlay.asif")):
    sys.exit("profile-reset-overlay left overlay.asif in the armed bundle")
if not os.path.isfile(os.path.join(prof, "vlfs.img")):
    sys.exit("reset took vlfs.img with it")

cfg_path = os.path.join(prof, "config.json")
cfg = json.load(open(cfg_path))
pub = cfg.get("updatePubkey")
cfg["cpus"] = 4
cfg["memoryMiB"] = 160
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, sort_keys=True)
    f.write("\n")
cfg2 = json.load(open(cfg_path))
if cfg2.get("cpus") != 4 or cfg2.get("memoryMiB") != 160 \
        or cfg2.get("updatePubkey") != pub:
    sys.exit("the settings save did not persist")
print("v3: clone verified (config + share/, fresh identity); overlay "
      "reset; save persisted cpus=4 memoryMiB=160")
PY

vgate_run c3 -- --profile '$RUN_DIR/ws3.virelaivm' --profile-init --timeout 60
vgate_assert c3 output-contains 'profile: loaded'
vgate_assert c3 output-contains 'cpus=4 memoryMiB=160'

vgate_file script-n3.txt <<'EOF'
smp
sysinfo
vf cat WS-KEEP.TXT
vf cat /disk/WS-DISK.TXT
echo ws-live-k3
EOF

vgate_run n3 -- --profile '$RUN_DIR/ws3.virelaivm' \
    --script '$RUN_DIR/script-n3.txt' \
    --script-expect 'ws-live-k3' --timeout 240
vgate_assert n3 output-contains '  memory: 160 MiB, cpus: 4'
vgate_assert n3 output-contains 'persistent ASIF overlay'
vgate_assert n3 serial-contains 'smp: cores=4 online=4'
vgate_assert n3 serial-contains 'vlfs: mounted /disk'
vgate_assert n3 serial-contains 'vf: cat WS-KEEP.TXT size='
vgate_assert n3 serial-contains 'vf: cat disk:WS-DISK.TXT size='
vgate_assert n3 serial-absent '[EXC]'
vgate_assert n3 python <<'PY'
import os, re, sys
run = os.environ["RUN_DIR"]
prof = os.path.join(run, "ws3.virelaivm")
if not os.path.isfile(os.path.join(prof, "overlay.asif")):
    sys.exit("n3: no overlay.asif -- the attach point did not re-mint")
nser = open(os.environ["VG_SER"], errors="replace").read()
vser = open(os.path.join(run, "vm-serial-v3.log"), errors="replace").read()
def cksum(ser, marker):
    i = ser.find(marker)
    if i < 0:
        sys.exit("no %r in serial" % marker)
    m = re.search(r"cksum=0x([0-9a-f]{4})", ser[i:])
    if not m:
        sys.exit("no cksum after %r" % marker)
    return m.group(1)
for marker in ("vf: cat WS-KEEP.TXT", "vf: cat disk:WS-DISK.TXT"):
    if cksum(vser, marker) != cksum(nser, marker):
        sys.exit("%r cksum changed across reset+reboot" % marker)
def usable(ser):
    m = re.search(r"usable=0x([0-9a-f]+)", ser)
    if not m:
        sys.exit("no sysinfo usable= line")
    return int(m.group(1), 16)
uv, un = usable(vser), usable(nser)
if un >= uv:
    sys.exit("usable RAM did not track the edit: v3=%#x n3=%#x" % (uv, un))
if un >= 160 * 1024 * 1024:
    sys.exit("n3 usable %#x above the 160 MiB allotment" % un)
print("n3: overlay re-minted; KEEP/DISK cksums survive reset+reboot; "
      "usable %#x -> %#x" % (uv, un))
PY
