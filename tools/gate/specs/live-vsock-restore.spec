# M115a (#2460): does Apple's standard VZVirtioSocketDevice survive a real
# VZ save/restore, and does a host listener still accept a guest connect
# afterwards? The custom-virtio devices are refused at
# validateSaveRestoreSupport (M70g G3), so vsock is the candidate
# restore-safe control channel the whole M115 arc rides on.
#
# Three legs, all observed on the host that runs this spec:
#   boot — plain `--vsock` boot: the guest arms DID 0x1053, `vsock 1208`
#          issues one OP_REQUEST to VMADDR_CID_HOST:1208, and the runner's
#          VZVirtioSocketListener accepts it (`VSOCK: listener accepted`);
#          an unlistened port answers RST (`vsock: refused`). This leg is
#          the proof the channel works at all, independent of restore.
#   save — `--vz-restore --vsock --vz-restore-save`: validation, boot,
#          marker, saveMachineStateTo, exit. The `vsock: ready did=0x1053`
#          serial line is the witness (a bare fixed line re-printed by the
#          `vsock` monitor command, so it recurs post-restore).
#   load — a NEW process restores the state and the serial-driven
#          `vsock 1208` verify command issues a FRESH guest connect; the
#          host listener accepting it is the positive verdict. The M119e
#          bound applies: when restoreMachineStateFrom saturates
#          VZErrorDomain Code=12 on the host, the leg asserts that refusal
#          verbatim instead (the recorded bound, not a fight against it).

vgate_name live-vsock-restore "M115a: VZVirtioSocketDevice across save/restore — post-restore guest connect accepted, or the Code=12 bound"
vgate_share none

vgate_file script.txt <<'EOF'
vsock
vsock 1208
vsock 9
echo vsock-boot-done
EOF

# Channel works at all: device enumerates, the guest connect reaches the
# host listener, and an unlistened port is refused honestly.
# warm-cold: boot (b) this leg's job is producing a REAL cold-boot state
#   for save/load to exercise — a checkpoint-restored boot leg would change
#   the provenance the spec exists to measure (ADR 0059 D7(b))
vgate_run boot -- --vsock --script '$RUN_DIR/script.txt' --script-expect 'vsock-boot-done' --timeout 90
vgate_assert boot serial-contains 'vsock: ready did=0x1053'
vgate_assert boot serial-contains 'vsock: connected port=1208'
vgate_assert boot serial-contains 'vsock: refused port=9'
vgate_assert boot output-contains 'VSOCK: ENABLED host-listen-port=1208'
vgate_assert boot output-contains 'VSOCK: host listener armed port=1208'
vgate_assert boot output-contains 'VSOCK: listener accepted guest connect dport=1208'
vgate_assert boot serial-absent '[EXC]'

# Save half: validation accepts the socket device, the guest boots and
# arms it, and the state is persisted for the load process.
vgate_run save -- --vz-restore --vsock --vz-restore-save '$RUN_DIR/vsv' \
  --vz-restore-witness 'vsock: ready did=0x1053' --timeout 90
vgate_assert save output-contains 'VZ-RESTORE: devices=vsock mode=save'
vgate_assert save output-contains 'VZ-RESTORE: validateSaveRestoreSupport passed'
vgate_assert save output-contains 'VZ-RESTORE: saveMachineStateTo completed state=2'
vgate_assert save output-contains 'VZ-RESTORE: SAVE PASS'
vgate_assert save serial-contains 'vsock: ready did=0x1053'
vgate_assert save serial-absent '[EXC]'

# Load half: a NEW process restores, resumes, and the verify command
# issues a fresh guest connect. rc 0 = the full verdict (CROSS-PROCESS
# PASS + the host listener accepting the post-restore connect); rc 1 is
# accepted ONLY for the M119e bound — `VZErrorDomain Code=12` at
# restoreMachineStateFrom, pinned verbatim by the python assert. Anything
# else FAILs.
vgate_run load -- --vz-restore --vsock --vz-restore-load '$RUN_DIR/vsv' \
  --vz-restore-witness 'vsock: ready did=0x1053' \
  --vz-restore-verify-command 'vsock 1208' \
  --vz-restore-verify-output 'vsock: connected port=1208' --timeout 90
vgate_allow_rc load 0 1
vgate_assert load output-contains 'VZ-RESTORE: devices=vsock mode=load'
vgate_assert load output-contains 'VZ-RESTORE: validateSaveRestoreSupport passed'
vgate_assert load python <<'PY'
import os
import re
from pathlib import Path
out = Path(os.environ['RUN_DIR'], 'run-%s.out' % os.environ['VG_TAG']).read_bytes()
if b'VZ-RESTORE: CROSS-PROCESS PASS' in out:
    # Positive verdict: the restore ran AND the fresh guest connect issued
    # by the verify command reached the host listener in this process.
    assert b'VZ-RESTORE: after-restore guest verify=vsock: connected port=1208' in out, out[-600:]
    assert b'VSOCK: listener accepted guest connect dport=1208' in out, 'restored but the post-restore guest connect never reached the host listener'
    save_out = Path(os.environ['RUN_DIR'], 'run-save.out').read_bytes()
    m = re.search(rb'SAVE PASS pid (\d+)', save_out)
    l = re.search(rb'CROSS-PROCESS PASS restored in pid (\d+)', out)
    assert m and l and m.group(1) != l.group(1), 'must be two different processes'
    print('load: CROSS-PROCESS PASS — post-restore guest connect accepted by the host listener')
else:
    refusal = b'ERROR: VZ-RESTORE: restore: restoreMachineStateFrom: Error Domain=VZErrorDomain Code=12' in out
    assert refusal, 'neither CROSS-PROCESS PASS nor the M119e Code=12 bound: ' + out[-600:].decode('utf-8', 'replace')
    print('load: M119e bound — restoreMachineStateFrom refused Code=12; verdict recorded in docs/hardware-contract.md')
PY
