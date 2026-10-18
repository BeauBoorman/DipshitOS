# live-session-persistence.spec — M120a (#2558): the `just session` path
# now wires the machine M115 proved. The setup hook drives
# `tools/session.sh --provision-only` — the session's own mint, not a
# gate-local reconstruction: profile init, the four SECRETS.TXT rows
# (vsock-ctl / os-update / agent-hmac / host-int), the OWNERS.TXT rows,
# the config.updatePubkey pin, and the vlfs.img format all land through
# the same code a human session runs.
#
# Two boots then ride that profile through the transports session.sh
# picks: `save` on the virtio-fs share posture (--save-capable —
# suspend=armed, the device set VZ accepts) and `cvc` on the default
# custom-virtio posture (suspend=unsupported — the honest verdict the
# PWR menu's Suspend used to answer `no_device` for want of the ctl
# channel at all). Both must auth on the ctl channel and mount the
# session-minted VLFS at /disk.
#
# HOST PREREQUISITES: none beyond the gate preamble — mkfs.vlfs builds
# from stock go inside session.sh; GOUPD.ELF/AGENTD.ELF staging is
# warn-only when the fork toolchain is absent.

vgate_name live-session-persistence "M120a #2558: just-session persistence wiring — provision via session.sh, vsock-ctl authed + VLFS mounted on both share postures"
vgate_share none
vgate_runner_flags -Xswiftc -DSPIKE

# Provision through the session script itself: an absent bundle is minted
# (manifest+config), the share gets every credential row and owner, the
# update trust pin matches the os-update row, and vlfs.img comes out
# formatted. The assertions read names and fields only — never values.
vgate_setup_python <<'PY'
import json, os, subprocess, sys
run = os.environ["RUN_DIR"]
prof = os.path.join(run, "session.virelaivm")
env = dict(os.environ)
env["VIRELAI_SESSION_PROFILE"] = prof
env["VIRELAI_SESSION_SKIP_BUILD"] = "1"
env["VIRELAI_SESSION_NO_GOTABWM"] = "1"
r = subprocess.run(["bash", "tools/session.sh",
                    "--provision-only", "--save-capable"],
                   capture_output=True, text=True, env=env)
sys.stdout.write(r.stdout)
if r.returncode != 0:
    sys.exit("session.sh --provision-only failed rc=%d: %s" % (r.returncode, r.stderr))
if "session: provisioning complete" not in r.stdout:
    sys.exit("no provisioning-complete receipt")

man = json.load(open(os.path.join(prof, "manifest.json")))
assert man["format"] == "virelaivm/1", man
cfg = json.load(open(os.path.join(prof, "config.json")))
assert cfg["baseImage"] == os.path.abspath("artifacts/disk.img"), cfg["baseImage"]

rows = {}
for line in open(os.path.join(prof, "share", "SECRETS.TXT")):
    f = line.rstrip("\n").split("\t")
    if f[0] and not f[0].startswith("#"):
        rows[f[0]] = f
want = {"vsock-ctl": ("0", None), "os-update": ("1000", "GOUPD.ELF"),
        "agent-hmac": ("1000", "AGENTD.ELF,GOTOP.ELF"),
        "host-int": ("1000", "GOTABWM.ELF")}
for name, (uid, bind) in want.items():
    assert name in rows, "missing %s row" % name
    assert rows[name][1] == uid, "%s uid=%s" % (name, rows[name][1])
    if bind is None:
        assert len(rows[name]) == 3, "%s should be unbound" % name
    else:
        assert len(rows[name]) == 4 and rows[name][3] == bind, \
            "%s binding=%s" % (name, rows[name][3:])
owners = {l.split("\t")[0]
          for l in open(os.path.join(prof, "share", "OWNERS.TXT"))
          if not l.startswith("#")}
for app in ("GOTABWM.ELF", "GOUPD.ELF", "GOTOP.ELF", "AGENTD.ELF"):
    assert app in owners, "missing OWNERS row for " + app

sys.path.insert(0, "tools/agentctl")
import agentctl
pub = agentctl.ed_public_key(bytes.fromhex(rows["os-update"][2])).hex()
assert cfg.get("updatePubkey") == pub, "updatePubkey does not match the os-update row"

mkfs = os.path.join(".build", "go", "mkfs.vlfs")
assert os.path.exists(mkfs), "session.sh did not build mkfs.vlfs"
r = subprocess.run([mkfs, "--check", os.path.join(prof, "vlfs.img")],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("vlfs.img not formatted: " + r.stdout + r.stderr)
print("setup: session.sh provisioned profile + 4 credential rows + owners "
      "+ updatePubkey pin; vlfs.img formatted")
PY

# The save-capable boot: the bundle's share rides virtio-fs — the session
# script's --save-capable launch line minus the window. The ctl listener
# must report suspend=armed (validateSaveRestoreSupport accepts this
# device set), the guest must auth, and the session-minted vlfs.img must
# mount and take a journaled write.
vgate_file script-save.txt <<'EOF'
write /disk/S-LIVE.TXT session-vlfs-bytes
vf cat /disk/S-LIVE.TXT
vsock ctl frobnicate
echo save-leg-done
EOF

vgate_run save -- --profile '$RUN_DIR/session.virelaivm' \
  --virtio-fs '$RUN_DIR/session.virelaivm/share' --vsock --vsock-ctl \
  --script '$RUN_DIR/script-save.txt' --script-expect 'save-leg-done' --timeout 90
vgate_assert save output-contains 'VSOCK-CTL: host listener armed port=1209 suspend=armed'
vgate_assert save serial-contains 'vlfs: mounted /disk'
vgate_assert save serial-contains 'write: ok'
vgate_assert save serial-contains 'vf: cat ok bytes='
vgate_assert save serial-count 'vsock-ctl: authed' 1
vgate_assert save serial-contains 'vsock-ctl: reply id=1 ok=false code=unknown_verb'
vgate_assert save serial-absent '[EXC]'

# The default boot: no share flag at all — the profile's devices.share
# arms --cvc-file exactly like a plain `just session`. The ctl channel
# still auths (the row serves on either transport) but suspend answers
# the honest `unsupported`: a custom-virtio share cannot be saved.
vgate_file script-cvc.txt <<'EOF'
vf cat /disk/S-LIVE.TXT
vsock ctl suspend
echo cvc-leg-done
EOF

vgate_run cvc -- --profile '$RUN_DIR/session.virelaivm' --vsock --vsock-ctl \
  --script '$RUN_DIR/script-cvc.txt' --script-expect 'cvc-leg-done' --timeout 90
vgate_assert cvc output-contains 'VSOCK-CTL: host listener armed port=1209 suspend=unsupported'
vgate_assert cvc serial-contains 'vlfs: mounted /disk'
vgate_assert cvc serial-contains 'vsock-ctl: suspend quiesce vlfs=synced'
vgate_assert cvc serial-contains 'vf: cat ok bytes='
vgate_assert cvc serial-count 'vsock-ctl: authed' 1
vgate_assert cvc serial-contains 'vsock-ctl: reply id=1 ok=false code=unsupported'
vgate_assert cvc serial-absent '[EXC]'
