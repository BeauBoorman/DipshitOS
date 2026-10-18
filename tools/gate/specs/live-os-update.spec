# live-os-update.spec — M115f (issue #2465) class-B gate: the OS upgrades
# itself. The guest stages a signed update set (OS.IMG + KERNEL.BIN +
# BOOTAA64.EFI + UPDATE.MF + UPDATE.SIG) to the profile share's UPDATE/
# via WriteFileSafe; the runner's opt-in --apply-update verifies the
# Ed25519 signature + every manifest hash, swaps the boot base (old ->
# <base>.prev), discards the persistent overlay.asif (stale sectors must
# not shadow the new image), and boots; --rollback-update swaps .prev
# back.
#
# Legs:
#   stage    — boot the ORIGINAL base on the machine's profile;
#              --apply-update reports "none staged" (the flag is safe to
#              carry permanently), `sysinfo` shows version=dev, then
#              GOUPD.ELF stages the signed set to /host/UPDATE.
#   badkey   — --apply-update with the WRONG Ed25519 public key refuses
#              sig_invalid before boot and leaves UPDATE/ in place.
#   apply    — --apply-update + the pinned key swaps the base and boots
#              the NEW kernel: sysinfo version=m115f-b.
#   rollback — --rollback-update restores .prev and boots the OLD kernel:
#              sysinfo version=dev.
#   tamper   — boot old, restage, then corrupt UPDATE/OS.IMG in-guest.
#   neg      — --apply-update on the torn set refuses hash_mismatch.
#
# Signing reuses the fleet's pinned test key (RFC 8032 TEST 1 — the same
# seed go-flint.spec stages as `agent-sign`, here the `os-update` slot-70
# entry bound to GOUPD.ELF); no new key material. The payload kernel pair
# is a real second build: zig build -Dos-version=m115f-b --prefix, so the
# update's KERNEL.BIN carries the version label sysinfo reports AND the
# loader's baked-in kernel pin (M113b) still verifies end to end.
#
# HOST PREREQUISITES:
#   bash tools/go/build-goupd.sh    -> .build/go/GOUPD.ELF   (staged + freshness-checked)
#   zig build                       -> zig-out/bin/*         (the "old" payload, gate preamble)
#
# exec-order: run 01 ends on the driver's `update: exit rc=` sentinel
# (printed on every path, so a failing stage ends promptly); sysinfo
# runs end on the 'uptime:' tail line; the tamper leg ends on `write: ok`.

vgate_name live-os-update "M115f #2465: guest-staged signed OS update — stage -> verify+swap -> sysinfo version changes -> rollback restores"
vgate_share none
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script-stage.txt <<'EOF'
sysinfo
exec GOUPD.ELF stage
EOF

vgate_file script-sysinfo.txt <<'EOF'
sysinfo
EOF

vgate_file script-tamper.txt <<'EOF'
exec GOUPD.ELF stage
EOF

vgate_file tamper-2.txt <<'EOF'
write UPDATE/OS.IMG tampered-bytes-not-an-image
EOF

vgate_setup_python <<'PY'
import hashlib, json, os, shutil, subprocess, sys

run = os.environ["RUN_DIR"]
repo = os.getcwd()
runner = os.path.join("host", "vm-runner", ".build", "release", "VMRunner")

# The fleet's pinned Ed25519 test key (RFC 8032 §7.1 TEST 1) — the same
# seed the go-flint spec stages as `agent-sign`. No new key material.
SEED = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
PUB  = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
UPDATE_VERSION = "m115f-b"

def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

# --- the "next" payload: a real second kernel pair --------------------------
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

# --- the profile + its updatable base ---------------------------------------
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
json.dump(cfg, open(cfg_path, "w"), indent=2, sort_keys=True)
print("profile minted; base.img is a private copy of artifacts/disk.img")

# --- share seeding ----------------------------------------------------------
share = os.path.join(prof, "share")
goupd = os.path.join(".build", "go", "GOUPD.ELF")
if not os.path.exists(goupd):
    sys.exit("GOUPD.ELF missing — build it first: bash tools/go/build-goupd.sh")
shutil.copy(goupd, os.path.join(share, "GOUPD.ELF"))
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\nos-update\t1000\t" + SEED + "\tGOUPD.ELF\n")
# The app-bound secret row is served only to a uid_system-owned image —
# OWNERS.TXT makes GOUPD.ELF that image (M97g #2083; same pair as
# go-flint's agent-sign/FLINT.ELF rows).
open(os.path.join(share, "OWNERS.TXT"), "w").write(
    "#v1\nGOUPD.ELF\t644\t0\t-\n")
nxt = os.path.join(share, "NEXT")
os.makedirs(nxt)
shutil.copy(new_k, os.path.join(nxt, "KERNEL.BIN"))
shutil.copy(new_e, os.path.join(nxt, "BOOTAA64.EFI"))
open(os.path.join(nxt, "VERSION.TXT"), "w").write(UPDATE_VERSION + "\n")
# No UPDATE/ yet — run 01's --apply-update must see "none staged".
print("staged share: GOUPD.ELF + SECRETS.TXT (os-update -> GOUPD.ELF) + NEXT/ payload")
PY

# --- 01 stage: old kernel reports, then stages the signed update ------------
vgate_run 01 -- --profile '$RUN_DIR/prof.virelaivm' --overlay-base '$RUN_DIR/base.img' \
  --apply-update --update-key d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a \
  --script '$RUN_DIR/script-stage.txt' --script-expect 'update: exit rc=' --timeout 600
vgate_assert 01 output-contains 'apply-update: none staged'
vgate_assert 01 serial-contains 'version=dev'
vgate_assert 01 serial-contains 'update: inputs KERNEL.BIN sha256='
vgate_assert 01 serial-contains 'update: staged ok version=m115f-b'
vgate_assert 01 serial-contains 'update: exit rc=0'
vgate_assert 01 python <<'PY'
import os, sys
share = os.path.join(os.environ["RUN_DIR"], "prof.virelaivm", "share", "UPDATE")
for name in ("OS.IMG", "KERNEL.BIN", "BOOTAA64.EFI", "UPDATE.MF", "UPDATE.SIG"):
    p = os.path.join(share, name)
    if not os.path.isfile(p):
        sys.exit("staged set missing " + name)
    print("staged %s %d bytes" % (name, os.path.getsize(p)))
mf = open(os.path.join(share, "UPDATE.MF")).read()
for want in ("kind=image", "version=m115f-b", "KERNEL.BIN", "BOOTAA64.EFI"):
    if want not in mf:
        sys.exit("UPDATE.MF lacks " + want)
if os.path.getsize(os.path.join(share, "UPDATE.SIG")) != 64:
    sys.exit("UPDATE.SIG is not 64 bytes")
print("staged UPDATE/ verified: manifest + 64-byte signature + members")
PY

# --- 02 badkey: a signature under the wrong key refuses by name -------------
vgate_run 02 -- --profile '$RUN_DIR/prof.virelaivm' --overlay-base '$RUN_DIR/base.img' \
  --apply-update --update-key 3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c \
  --timeout 60
vgate_allow_rc 02 1
vgate_assert 02 output-contains 'sig_invalid'
vgate_assert 02 python <<'PY'
import hashlib, os, sys
run = os.environ["RUN_DIR"]
# The refused set is left in place (evidence + fail-closed retry) and the
# base image is untouched — still the private copy of artifacts/disk.img.
share = os.path.join(run, "prof.virelaivm", "share", "UPDATE")
if not os.path.isdir(share):
    sys.exit("refused staging vanished")
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
if h(os.path.join(run, "base.img")) != h("artifacts/disk.img"):
    sys.exit("refused run still swapped the base")
print("refused set retained; base untouched")
PY

# --- 03 apply: verify + swap, then the new kernel boots ---------------------
vgate_run 03 -- --profile '$RUN_DIR/prof.virelaivm' --overlay-base '$RUN_DIR/base.img' \
  --apply-update --update-key d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a \
  --script '$RUN_DIR/script-sysinfo.txt' --script-expect 'uptime:' --timeout 300
vgate_assert 03 output-contains 'apply-update: applied version=m115f-b'
vgate_assert 03 output-contains 'apply-update: overlay reset'
vgate_assert 03 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 03 serial-contains 'RCPT stage=kernel sha256='
vgate_assert 03 serial-contains 'version=m115f-b'
vgate_assert 03 serial-absent 'version=dev'
vgate_assert 03 python <<'PY'
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
# The overlay.asif present now was minted fresh by THIS boot (the apply
# discarded the old one — the 'overlay reset' output line proves the
# discard; post-run existence alone would be a false signal).
ov = os.path.join(run, "prof.virelaivm", "overlay.asif")
if not os.path.exists(ov):
    sys.exit("no overlay.asif for the applied boot")
print("base swapped (sha matches staged image), .prev retained, overlay re-minted")
PY

# --- 04 rollback: .prev swaps back and the old kernel boots -----------------
vgate_run 04 -- --profile '$RUN_DIR/prof.virelaivm' --overlay-base '$RUN_DIR/base.img' \
  --rollback-update \
  --script '$RUN_DIR/script-sysinfo.txt' --script-expect 'uptime:' --timeout 300
vgate_assert 04 output-contains 'apply-update: rollback restored'
vgate_assert 04 serial-contains 'version=dev'
vgate_assert 04 serial-absent 'version=m115f-b'
vgate_assert 04 python <<'PY'
import hashlib, os, sys
run = os.environ["RUN_DIR"]
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
if h(os.path.join(run, "base.img")) != h("artifacts/disk.img"):
    sys.exit("rollback did not restore the pre-update base")
print("rollback restored the original base image")
PY

# --- 05 tamper: restage, then corrupt the staged image in-guest -------------
vgate_run 05 -- --profile '$RUN_DIR/prof.virelaivm' --overlay-base '$RUN_DIR/base.img' \
  --script '$RUN_DIR/script-tamper.txt' \
  --script2 '$RUN_DIR/tamper-2.txt' --script2-after 'update: exit rc=0' \
  --script-expect 'write: ok' --timeout 600
vgate_assert 05 serial-contains 'update: staged ok version=m115f-b'
vgate_assert 05 serial-contains 'write: ok'
vgate_assert 05 python <<'PY'
import os, sys
p = os.path.join(os.environ["RUN_DIR"], "prof.virelaivm", "share", "UPDATE", "OS.IMG")
if not os.path.isfile(p):
    sys.exit("restaged UPDATE/OS.IMG missing")
if os.path.getsize(p) > 4096:
    sys.exit("tamper did not truncate OS.IMG (size %d)" % os.path.getsize(p))
print("OS.IMG tampered to %d bytes" % os.path.getsize(p))
PY

# --- 06 neg: the torn staged set refuses by name ----------------------------
vgate_run 06 -- --profile '$RUN_DIR/prof.virelaivm' --overlay-base '$RUN_DIR/base.img' \
  --apply-update --update-key d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a \
  --timeout 60
vgate_allow_rc 06 1
vgate_assert 06 output-contains 'hash_mismatch'
vgate_assert 06 python <<'PY'
import hashlib, os, sys
run = os.environ["RUN_DIR"]
h = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
if h(os.path.join(run, "base.img")) != h("artifacts/disk.img"):
    sys.exit("tampered set still swapped the base")
print("hash_mismatch refused; base still the rolled-back original")
PY
