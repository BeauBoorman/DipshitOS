# live-reboot.spec -- live reboot and shutdown from the shell.
# Mirrors tools/verify-live-reboot.sh (claim 0527, M1.5 hard gate 6).
# Real EFI ResetSystem calls:
#   reboot: cold reset -> machine resets, second banner + fresh map key, stays running (rc=1 timeout).
#   shutdown: power-off -> runner reports VM left running state (state=0, rc=1).

vgate_name live-reboot "live reboot/shutdown via EFI ResetSystem on VZ"
vgate_share none
vgate_repeat 1 BOOTS

vgate_file script-reboot.txt <<'EOF'
reboot
EOF

vgate_file script-shutdown.txt <<'EOF'
shutdown
EOF

# warm-cold: reboot,shutdown (b) the legs exercise EFI ResetSystem — a
#   leg that restores a checkpoint and then reboots tests reboot semantics,
#   not warm semantics; restore/reset machinery stays cold (ADR 0059 D7(b))
vgate_run reboot -- --script '$RUN_DIR/script-reboot.txt' --script-expect '__NEVER_EXPECTED__' --timeout 45
vgate_allow_rc reboot 1

vgate_assert reboot serial-echo reboot
vgate_assert reboot serial-count 'kernel has seized control' 2
vgate_assert reboot output-contains 'not observed within'
vgate_assert reboot python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
keys = set(re.findall(r"key=0x[0-9a-f]+", ser))
if len(keys) < 2:
    sys.exit("FAIL: reboot did not produce fresh memory map key (saw %d distinct keys)" % len(keys))
print("reboot keys ok (%d distinct)" % len(keys))
PY

vgate_run shutdown -- --script '$RUN_DIR/script-shutdown.txt' --script-expect '__NEVER_EXPECTED__' --timeout 45
vgate_allow_rc shutdown 1

vgate_assert shutdown serial-echo shutdown
vgate_assert shutdown output-contains '(state=0)'
vgate_assert shutdown python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
banners = ser.count("kernel has seized control")
if banners != 1:
    sys.exit("FAIL: shutdown produced %d banners (want exactly 1)" % banners)
print("shutdown single boot ok")
PY
