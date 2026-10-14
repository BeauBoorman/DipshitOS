# Real VZ machine-state restore, not a framebuffer snapshot or a reboot.
#
# M70g G3 (#1459) extends the #1370 same-process probe with what VZ actually
# does beyond it, all observed on macOS 27.2 (26B5086k) 2026-09-18:
#   save/load  cross-process: the `save` run (one VMRunner process) stores a
#              RAM-only clipboard marker, saves state + the ASIF overlay + the
#              marker + the platform machineIdentifier into $RUN_DIR/vzsr and
#              exits; the `load` run (a NEW process) restores from it without
#              booting and must recover the marker by a fresh serial query.
#   gpu        virtio-gpu attached (`--display`, headless): full cycle PASS.
#   usb        USB HID keyboard+pointer on XHCI (`--input`): full cycle PASS.
#   msd        USB mass storage on XHCI (`--usb-msd`): validation passes and the
#              save completes every time; the restore PASSED 8 of 9 cycles and
#              once (under this harness) failed VZErrorRestore 12 "permission
#              denied" — not reproduced by file shape, location, or preceding
#              run. The run therefore asserts the deterministic half hard and
#              accepts exactly those two cycle outcomes; anything else FAILs.
#   cvc        custom-virtio attached: VZ REFUSES at validateSaveRestoreSupport
#              (VZErrorDomain 2 "Unsupported custom virtio device in
#              configuration.") — the negative result, pinned verbatim.
#   gpu3d      gpu3d-metal attached: the M102 VIR1 render device is itself a
#              VZCustomVirtioDevice; VZ REFUSES the same way (#2261). VZ has
#              no detach/quiesce API for live devices, so the contract is a
#              documented refusal and the runner error names the blocking
#              device(s) — asserted verbatim for both negative runs.
# The SPIKE runner variant is needed for the `cvc`/`gpu3d` runs (custom-virtio
# types); every other run is byte-identical on it.
vgate_name live-vz-restore "Real VZ pause/save/stop/restore/resume preserves a RAM-only clipboard marker; M70g G3 cross-process + device verdicts"
vgate_runner_flags -Xswiftc -DSPIKE
vgate_share none

vgate_run 01 -- --vz-restore --timeout 90

# VZVirtualMachineState SDK raw values: stopped=0, running=1, paused=2.
vgate_assert 01 output-contains 'VZ-RESTORE: validateSaveRestoreSupport passed'
vgate_assert 01 output-contains 'VZ-RESTORE: pause completed state=2'
vgate_assert 01 output-contains 'VZ-RESTORE: saveMachineStateTo completed state=2'
vgate_assert 01 output-contains 'VZ-RESTORE: stop completed state=0'
vgate_assert 01 output-contains 'VZ-RESTORE: restoreMachineStateFrom completed state=2'
vgate_assert 01 output-contains 'VZ-RESTORE: resume completed state=1'
vgate_assert 01 output-contains 'VZ-RESTORE: PASS CPU/memory/device restore; fresh serial query recovered RAM marker'
vgate_assert 01 serial-absent '[EXC]'
vgate_assert 01 python <<'PY'
import os
import re
from pathlib import Path
serial = Path(os.environ['VG_SER']).read_bytes()
markers = re.findall(rb'^clip: (VZSR-[0-9A-F-]{36})$', serial, re.M)
assert len(markers) == 2 and markers[0] == markers[1], markers
assert serial.count(b'VirelaiOS kernel has seized control.') == 1, 'reboot is not restore'
assert serial.count(b'clip: stored') == 1, 'marker must only be written before save'
PY

# --- M70g G3: cross-process --------------------------------------------------
vgate_run save -- --vz-restore --vz-restore-save '$RUN_DIR/vzsr' --timeout 90
vgate_assert save output-contains 'VZ-RESTORE: devices=headless-base mode=save'
vgate_assert save output-contains 'platform: machineIdentifier persisted to'
vgate_assert save output-contains 'VZ-RESTORE: validateSaveRestoreSupport passed'
vgate_assert save output-contains 'VZ-RESTORE: saveMachineStateTo completed state=2'
vgate_assert save output-contains 'VZ-RESTORE: stop completed state=0'
vgate_assert save output-contains 'VZ-RESTORE: SAVE PASS'
vgate_assert save serial-absent '[EXC]'
vgate_assert save python <<'PY'
import os
import re
from pathlib import Path
serial = Path(os.environ['VG_SER']).read_bytes()
markers = re.findall(rb'^clip: (VZSR-[0-9A-F-]{36})$', serial, re.M)
assert len(markers) == 1, markers
assert serial.count(b'clip: stored') == 1, 'marker written exactly once, before save'
state = Path(os.environ['RUN_DIR']) / 'vzsr'
for name in ('state.vzsave', 'overlay.asif', 'marker.txt', 'machine-id.bin'):
    assert (state / name).stat().st_size > 0, name
assert (state / 'marker.txt').read_text().strip() == markers[0].decode(), 'persisted marker must be the guest one'
PY

# The load run is a NEW VMRunner process: it must not boot (no kernel banner in
# its own serial log) and must recover the marker the save process stored.
# KEEP `save` AND `load` ADJACENT: the harness-owned `--vars $RUN_DIR/efi-vars.bin`
# is shared by every run of this spec, and a boot inserted between the two
# would rewrite the variable store the saved state was taken against.
vgate_run load -- --vz-restore --vz-restore-load '$RUN_DIR/vzsr' --timeout 90
vgate_assert load output-contains 'VZ-RESTORE: devices=headless-base mode=load'
vgate_assert load output-contains 'platform: machineIdentifier adopted from'
vgate_assert load output-contains 'VZ-RESTORE: validateSaveRestoreSupport passed'
vgate_assert load output-contains 'VZ-RESTORE: restoreMachineStateFrom completed state=2'
vgate_assert load output-contains 'VZ-RESTORE: resume completed state=1'
vgate_assert load output-contains 'VZ-RESTORE: final stop completed state=0'
vgate_assert load output-contains 'VZ-RESTORE: CROSS-PROCESS PASS restored in pid'
vgate_assert load serial-absent 'VirelaiOS kernel has seized control.'
vgate_assert load serial-absent 'clip: stored'
vgate_assert load serial-absent '[EXC]'
vgate_assert load python <<'PY'
import os
import re
from pathlib import Path
run = Path(os.environ['RUN_DIR'])
save_out = (run / 'run-save.out').read_bytes()
m = re.search(rb'SAVE PASS pid (\d+) saved state\+overlay\+marker (VZSR-[0-9A-F-]{36})', save_out)
assert m, save_out[-400:]
save_pid, saved = m.group(1), m.group(2)
load_out = Path(os.environ['RUN_DIR'], 'run-%s.out' % os.environ['VG_TAG']).read_bytes()
l = re.search(rb'CROSS-PROCESS PASS restored in pid (\d+)', load_out)
assert l and l.group(1) != save_pid, 'must be two different processes'
serial = Path(os.environ['VG_SER']).read_bytes()
markers = re.findall(rb'^clip: (VZSR-[0-9A-F-]{36})$', serial, re.M)
assert markers == [saved], (markers, saved)
assert not (run / 'vzsr').exists(), 'state dir is removed on success'
PY

# --- M70g G3: devices attached -------------------------------------------------
vgate_run gpu -- --vz-restore --display --timeout 90
vgate_assert gpu output-contains 'VZ-RESTORE: devices=virtio-gpu mode=same-process'
vgate_assert gpu output-contains 'VZ-RESTORE: validateSaveRestoreSupport passed'
vgate_assert gpu output-contains 'VZ-RESTORE: PASS CPU/memory/device restore; fresh serial query recovered RAM marker'
vgate_assert gpu serial-absent '[EXC]'
vgate_assert gpu python <<'PY'
import os
import re
from pathlib import Path
serial = Path(os.environ['VG_SER']).read_bytes()
markers = re.findall(rb'^clip: (VZSR-[0-9A-F-]{36})$', serial, re.M)
assert len(markers) == 2 and markers[0] == markers[1], markers
assert serial.count(b'VirelaiOS kernel has seized control.') == 1, 'reboot is not restore'
PY

vgate_run usb -- --vz-restore --input --timeout 90
vgate_assert usb output-contains 'VZ-RESTORE: devices=usb-hid(xhci) mode=same-process'
vgate_assert usb output-contains 'VZ-RESTORE: validateSaveRestoreSupport passed'
vgate_assert usb output-contains 'VZ-RESTORE: PASS CPU/memory/device restore; fresh serial query recovered RAM marker'
vgate_assert usb serial-absent '[EXC]'
vgate_assert usb python <<'PY'
import os
import re
from pathlib import Path
serial = Path(os.environ['VG_SER']).read_bytes()
markers = re.findall(rb'^clip: (VZSR-[0-9A-F-]{36})$', serial, re.M)
assert len(markers) == 2 and markers[0] == markers[1], markers
assert serial.count(b'VirelaiOS kernel has seized control.') == 1, 'reboot is not restore'
PY

vgate_setup_python <<'PY'
import os
with open(os.path.join(os.environ['RUN_DIR'], 'msd.img'), 'wb') as f:
    f.truncate(8 * 1024 * 1024)
PY
# Measurement run (see header): rc 0 = full cycle PASS; rc 1 is accepted ONLY
# for the one observed refusal shape, pinned verbatim by the python assert.
vgate_run msd -- --vz-restore --usb-msd '$RUN_DIR/msd.img' --timeout 90
vgate_allow_rc msd 0 1
vgate_assert msd output-contains 'VZ-RESTORE: devices=usb-msd(xhci) mode=same-process'
vgate_assert msd output-contains 'VZ-RESTORE: validateSaveRestoreSupport passed'
vgate_assert msd output-contains 'VZ-RESTORE: saveMachineStateTo completed state=2'
vgate_assert msd output-contains 'VZ-RESTORE: stop completed state=0'
vgate_assert msd serial-absent '[EXC]'
vgate_assert msd python <<'PY'
import os
import re
from pathlib import Path
out = Path(os.environ['RUN_DIR'], 'run-%s.out' % os.environ['VG_TAG']).read_bytes()
serial = Path(os.environ['VG_SER']).read_bytes()
markers = re.findall(rb'^clip: (VZSR-[0-9A-F-]{36})$', serial, re.M)
assert serial.count(b'VirelaiOS kernel has seized control.') == 1, 'reboot is not restore'
if b'VZ-RESTORE: PASS CPU/memory/device restore; fresh serial query recovered RAM marker' in out:
    assert len(markers) == 2 and markers[0] == markers[1], markers
    print('msd: full cycle PASS')
else:
    refusal = (b'ERROR: VZ-RESTORE: restore: restoreMachineStateFrom: Error Domain=VZErrorDomain Code=12' in out
               and b'permission denied' in out)
    assert refusal, 'neither the PASS verdict nor the one observed refusal shape: ' + out[-600:].decode('utf-8', 'replace')
    assert len(markers) == 1, markers
    print('msd: observed refusal shape (VZErrorRestore 12 permission denied) -- recorded, see hardware-contract')
PY

# The negative result: VZ refuses the custom-virtio device at validation, before
# any boot. Pinned verbatim so a future macOS that accepts it fails this run
# loudly (and gets a new hardware-contract row). #2261: the runner error must
# also name the blocking device(s), not only list the attached set.
vgate_run cvc -- --vz-restore --custom-virtio --timeout 90
vgate_allow_rc cvc 1
vgate_assert cvc output-contains 'VZ-RESTORE: devices=custom-virtio mode=same-process'
vgate_assert cvc output-contains 'VZ-RESTORE: validateSaveRestoreSupport REFUSED devices=custom-virtio'
vgate_assert cvc output-contains 'Unsupported custom virtio device in configuration.'
vgate_assert cvc output-contains 'ERROR: --vz-restore validateSaveRestoreSupport failed'
vgate_assert cvc output-contains 'Blocking device(s): custom-virtio'

# The M102 VIR1 render device is a VZCustomVirtioDevice too; #2261 admits
# --gpu3d-metal under --vz-restore so its verdict is measured like the other
# device knobs. The observed refusal is pinned verbatim.
vgate_run gpu3d -- --vz-restore --gpu3d-metal --timeout 90
vgate_allow_rc gpu3d 1
vgate_assert gpu3d output-contains 'VZ-RESTORE: devices=gpu3d-metal mode=same-process'
vgate_assert gpu3d output-contains 'VZ-RESTORE: validateSaveRestoreSupport REFUSED devices=gpu3d-metal'
vgate_assert gpu3d output-contains 'Unsupported custom virtio device in configuration.'
vgate_assert gpu3d output-contains 'Blocking device(s): gpu3d-metal'

# Both custom-virtio attachments at once: the refusal names both blockers.
vgate_run cvboth -- --vz-restore --custom-virtio --gpu3d-metal --timeout 90
vgate_allow_rc cvboth 1
vgate_assert cvboth output-contains 'VZ-RESTORE: devices=custom-virtio,gpu3d-metal mode=same-process'
vgate_assert cvboth output-contains 'VZ-RESTORE: validateSaveRestoreSupport REFUSED devices=custom-virtio,gpu3d-metal'
vgate_assert cvboth output-contains 'Unsupported custom virtio device in configuration.'
vgate_assert cvboth output-contains 'Blocking device(s): custom-virtio,gpu3d-metal'

# --- M83g #1780: cross-process restore with a live VirtioFS-backed Go seat --
# A real session/settings fixture is read by the guest before save. The Go
# seat emits its in-memory state only after a composite tick; the load process
# must recover that witness after resuming the saved VM, then issue a fresh
# `vf cat` through the restored FUSE queue. The host asserts fixture bytes
# survived unchanged. Do not insert a run between save and load: the machine
# identifier, ASIF overlay and virtio-fs directory are one restore pair.
vgate_setup_python <<'PY'
import os, shutil, subprocess
run = os.environ["RUN_DIR"]
share = os.path.join(run, "share")
os.makedirs(share, exist_ok=True)
subprocess.run(["bash", "tools/go/build-gotabwm.sh"], check=True)
shutil.copy2(".build/go/GOTABWM.ELF", os.path.join(share, "GOTABWM.ELF"))

settings = b"#v2\nwm=gotabwm\ntheme=light\n"
(open(os.path.join(share, "SETTINGS.TXT"), "wb")).write(settings)
(open(os.path.join(share, "VZRESTORE.WITNESS"), "wb")).write(b"wake-fuse-ok\n")

def record(title, flags, binary):
    return (title.encode().ljust(32, b"\0") + bytes([flags]) + bytes(12) +
            binary.encode().ljust(24, b"\0"))

session = bytes([2, 2, 2, 7, 0, 0]) + record("Notes", 1, "NOTE.ELF") + record("Calc", 0, "GOCALC.ELF")
(open(os.path.join(share, "SESSION.TABS"), "wb")).write(session)
print("staged VirtioFS restore share: GOTABWM.ELF=%d settings=%d session=%d witness=%d" %
      (os.path.getsize(os.path.join(share, "GOTABWM.ELF")), len(settings),
       len(session), len(b"wake-fuse-ok\n")))
PY

vgate_run fs-save -- --vz-restore --display --virtio-fs '$RUN_DIR/share' \
  --vz-restore-save '$RUN_DIR/vzfs' \
  --vz-restore-witness 'gotabwm: restore witness wm=gotabwm theme=light file=wake-fuse-ok Notes,Calc pin=1,0 active=1' \
  --timeout 120
vgate_assert fs-save output-contains 'VZ-RESTORE: devices=virtio-gpu,virtio-fs mode=save'
vgate_assert fs-save output-contains 'VZ-RESTORE: validateSaveRestoreSupport passed'
vgate_assert fs-save output-contains 'VZ-RESTORE: before-save guest witness=gotabwm: restore witness wm=gotabwm theme=light file=wake-fuse-ok Notes,Calc pin=1,0 active=1'
vgate_assert fs-save output-contains 'VZ-RESTORE: SAVE PASS'
vgate_assert fs-save serial-contains 'virtio-fs: ready did=0x105a'
vgate_assert fs-save serial-contains 'gotabwm: settings wm=gotabwm'
vgate_assert fs-save serial-contains 'gotabwm: tokens theme=light'
vgate_assert fs-save serial-contains 'gotabwm: session load n=2 mode=restore'
vgate_assert fs-save serial-contains 'gotabwm: session titles=Notes,Calc pin=1,0 active=1'
vgate_assert fs-save serial-absent '[EXC]'
vgate_assert fs-save python <<'PY'
import os
from pathlib import Path
share = Path(os.environ["RUN_DIR"], "share")
session = (bytes([2, 2, 2, 7, 0, 0]) +
           b"Notes".ljust(32, b"\0") + bytes([1]) + bytes(12) + b"NOTE.ELF".ljust(24, b"\0") +
           b"Calc".ljust(32, b"\0") + bytes([0]) + bytes(12) + b"GOCALC.ELF".ljust(24, b"\0"))
assert (share / "SETTINGS.TXT").read_bytes() == b"#v2\nwm=gotabwm\ntheme=light\n"
assert (share / "SESSION.TABS").read_bytes() == session
assert (share / "VZRESTORE.WITNESS").read_bytes() == b"wake-fuse-ok\n"
PY

vgate_run fs-load -- --vz-restore --display --virtio-fs '$RUN_DIR/share' \
  --vz-restore-load '$RUN_DIR/vzfs' \
  --vz-restore-witness 'gotabwm: restore witness wm=gotabwm theme=light file=wake-fuse-ok Notes,Calc pin=1,0 active=1' \
  --vz-restore-verify-command 'vf open VZRESTORE.LARGE; vf write 1 4097; vf fsync 1; vf close 1' \
  --vz-restore-verify-output 'vf: close 1 ok' \
  --timeout 120
vgate_assert fs-load output-contains 'VZ-RESTORE: devices=virtio-gpu,virtio-fs mode=load'
vgate_assert fs-load output-contains 'VZ-RESTORE: validateSaveRestoreSupport passed'
vgate_assert fs-load output-contains 'VZ-RESTORE: after-restore guest witness=gotabwm: restore witness wm=gotabwm theme=light file=wake-fuse-ok Notes,Calc pin=1,0 active=1'
vgate_assert fs-load output-contains 'VZ-RESTORE: after-restore guest verify=vf: close 1 ok'
vgate_assert fs-load output-contains 'VZ-RESTORE: CROSS-PROCESS PASS'
vgate_assert fs-load serial-absent 'VirelaiOS kernel has seized control.'
vgate_assert fs-load serial-absent '[EXC]'
vgate_assert fs-load serial-contains 'vf: write 1 n=4097 wrote=4097 chunks=3'
vgate_assert fs-load serial-contains 'vf: fsync 1 ok'
vgate_assert fs-load serial-contains 'vf: close 1 ok'
vgate_assert fs-load python <<'PY'
import os
from pathlib import Path
share = Path(os.environ["RUN_DIR"], "share")
assert (share / "SETTINGS.TXT").read_bytes() == b"#v2\nwm=gotabwm\ntheme=light\n"
assert (share / "VZRESTORE.WITNESS").read_bytes() == b"wake-fuse-ok\n"
data = (share / "SESSION.TABS").read_bytes()
assert data[0:6] == bytes([2, 2, 2, 7, 0, 0]) and len(data) == 6 + 2 * 69, data
pattern = bytes(((i & 0xff) ^ ((i >> 8) & 0xff)) for i in range(4097))
assert (share / "VZRESTORE.LARGE").read_bytes() == pattern
assert (Path(os.environ["RUN_DIR"]) / "vzfs").exists() is False
PY

# --- flag negatives (parse-time, no boot) -------------------------------------
vgate_run incompatible -- --vz-restore --cvc-snap
vgate_allow_rc incompatible 1
vgate_assert incompatible output-contains 'ERROR: --vz-restore is a standalone headless save/restore probe'

vgate_run unbounded -- --vz-restore --timeout 0
vgate_allow_rc unbounded 1
vgate_assert unbounded output-contains 'ERROR: --vz-restore requires --timeout in (0, 600] seconds'

vgate_run missing -- --timeout --vz-restore
vgate_allow_rc missing 1
vgate_assert missing output-contains 'ERROR: --vz-restore: --timeout requires a value.'

vgate_run invalid -- --vz-restore --timeout banana
vgate_allow_rc invalid 1
vgate_assert invalid output-contains 'ERROR: --vz-restore: --timeout requires a numeric value.'

vgate_run both -- --vz-restore --vz-restore-save '$RUN_DIR/x' --vz-restore-load '$RUN_DIR/x' --timeout 30
vgate_allow_rc both 1
vgate_assert both output-contains 'ERROR: --vz-restore-save and --vz-restore-load are mutually exclusive'

vgate_run loadmissing -- --vz-restore --vz-restore-load '$RUN_DIR/absent' --timeout 30
vgate_allow_rc loadmissing 1
vgate_assert loadmissing output-contains 'ERROR: --vz-restore-load: no valid machine-id.bin'

vgate_run verifyonsave -- --vz-restore --vz-restore-save '$RUN_DIR/verify-save' \
  --vz-restore-witness 'witness' \
  --vz-restore-verify-command 'vf cat VZRESTORE.WITNESS' \
  --vz-restore-verify-output 'vf: cat ok bytes=13' --timeout 30
vgate_allow_rc verifyonsave 1
vgate_assert verifyonsave output-contains 'ERROR: --vz-restore-verify-command and --vz-restore-verify-output require a witness and a run that resumes the VM.'
