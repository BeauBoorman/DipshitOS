# vgate-warm-smoke.spec -- M131b (#2639, ADR 0059) evidence for the
# warm-checkpoint leg primitives: boot once, checkpoint at a quiescent
# prompt, restore per leg, nothing crosses.
#
#   ck   the dedicated base boot (D4): settle on `tasks user-el0 reaped`
#        then a fresh `virelai> ` prompt, pause/save/stop. No workload.
#   w1/w2 strict warm legs (D8) sharing ck. w1 writes a nonce into guest
#        RAM (the `clip` clipboard) and into the share (W1.NONCE); w2 must
#        find BOTH absent — it restored the pristine checkpoint, not w1's
#        residue (D3 isolation positive control). Both also prove the D6
#        epoch: the base-boot-only banner `VirelaiOS kernel has seized
#        control.` never reaches a warm leg's serial.
#   f1   restores a deliberately TRUNCATED state.vzsave clone — the refusal
#        is machine-distinguishable (rc 75 + `VZ-RESTORE: refused code=N`),
#        degrades to exactly one cold boot, and records
#        `warm=fallback(<code>)` (D8).
# Saveable devices only: `vgate_share arm-virtiofs`, no custom-virtio.
# exec-order: assert-proven -- every script ends on its own echo marker;
# asserts read guest output, never the script's echo alone.
vgate_name vgate-warm-smoke "M131b warm-checkpoint legs: per-leg clones, epoch, strict restore, refusal fallback"
vgate_share arm-virtiofs
vgate_repeat 1

vgate_file w1.txt <<'EOF'
clip W1NONCE
clip
write W1.NONCE w1-was-here
cat W1.NONCE
echo w1-done
EOF
vgate_file w2.txt <<'EOF'
clip
cat W1.NONCE
echo w2-done
EOF
vgate_file f1.txt <<'EOF'
echo f1-alive
EOF

vgate_checkpoint ck -- --timeout 240

vgate_run w1 --from-checkpoint ck --warm-strict -- --script '$RUN_DIR/w1.txt' --script-after 'tasks user-el0 reaped' --script-expect w1-done --timeout 120
vgate_assert w1 serial-contains 'clip: stored'
vgate_assert w1 serial-contains 'clip: W1NONCE'
vgate_assert w1 serial-contains 'w1-done'
vgate_assert w1 serial-absent 'VirelaiOS kernel has seized control.'
vgate_assert w1 output-contains 'warm leg'
vgate_assert w1 output-contains 're-based onto the post-restore handshake'
vgate_assert w1 python <<'PY'
import os
from pathlib import Path
share = Path(os.environ["VG_SHARE"])
assert share.name == "share", share
assert (share / "W1.NONCE").exists(), "w1's nonce file must land in ITS OWN share clone"
bundle = Path(os.environ["RUN_DIR"]) / "ckpt-ck"
assert not (bundle / "share" / "W1.NONCE").exists(), "the checkpoint bundle must stay immutable"
PY

vgate_run w2 --from-checkpoint ck --warm-strict -- --script '$RUN_DIR/w2.txt' --script-after 'tasks user-el0 reaped' --script-expect w2-done --timeout 120
vgate_assert w2 serial-contains 'clip: empty'
vgate_assert w2 serial-contains 'W1.NONCE: not found'
vgate_assert w2 serial-contains 'w2-done'
vgate_assert w2 serial-absent 'VirelaiOS kernel has seized control.'
vgate_assert w2 python <<'PY'
import os
from pathlib import Path
share = Path(os.environ["VG_SHARE"])
assert not (share / "W1.NONCE").exists(), "w2 must restore the pristine checkpoint, not w1's residue"
PY

# f1: the fallback leg — provable on a host where every restore refuses too.
vgate_run f1 --from-checkpoint ck --warm-corrupt truncate-state -- --script '$RUN_DIR/f1.txt' --script-after 'tasks user-el0 reaped' --script-expect f1-alive --timeout 120
vgate_assert f1 serial-contains 'f1-alive'
vgate_assert f1 python <<'PY'
import os
from pathlib import Path
warm = Path(os.environ["RUN_DIR"]) / "run-f1-warm.out"
assert warm.exists(), "the refused warm attempt's output must be kept as evidence"
assert "VZ-RESTORE: refused code=" in warm.read_text(), warm.read_text()[-400:]
PY
