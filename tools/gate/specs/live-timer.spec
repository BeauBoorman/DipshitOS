# live-timer.spec -- real CNTP PPI delivery through the EL1 IRQ vector.
# Mirrors tools/verify-live-timer.sh (claim 9187): five IRQ-serviced ticks,
# no fallback polls, shell alive throughout.
# M170a #3033 (ADR 0060): a `timer probe 50` leg arms one kernel deadline —
# a non-heartbeat comparator fire — and pins the measured lateness plus the
# deadline_irqs counter, while the heartbeat text stays byte-identical.

vgate_name live-timer "CNTP PPI delivery, 5 IRQ ticks, no polls + deadline probe"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_note "script: timer probe 50 / timer / echo rx-timer-ok; expect heartbeat ticks=5 irq=5 poll=0"

vgate_file script.txt <<'EOF'
timer probe 50
EOF

vgate_file script2.txt <<'EOF'
timer
echo rx-timer-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' --script2-after 'timer probe ms=50 late_us=' \
    --script-expect 'timer heartbeat ticks=5 irq=5 poll=0' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'interrupts: gic='
vgate_assert 01 serial-contains 'timer: armed=1'
vgate_assert 01 serial-contains 'rx-timer-ok'
vgate_assert 01 serial-contains 'timer irq delivered ppi=0x1e irq_ticks=1'
vgate_assert 01 serial-contains 'timer heartbeat ticks=5 irq=5 poll=0'
vgate_assert 01 serial-contains 'timer probe ms=50 late_us='

# The probe line is the deadline overlay's own evidence: the measured
# lateness under the proposed 5000 us bound, and deadline_irqs grown on
# the post-fire `timer` row — a deadline IRQ that moved no tick counter.
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
m = re.search(r"timer probe ms=50 late_us=(\d+)", ser)
assert m, "no probe result line in the serial log"
late = int(m.group(1))
assert late < 5000, "probe late_us=%d exceeds the proposed 5000 us bound" % late
rows = [l for l in ser.splitlines() if "timer: armed=" in l]
assert rows, "no 'timer:' row in the serial log"
dm = re.search(r"deadline_irqs=(\d+)", rows[-1])
assert dm and int(dm.group(1)) >= 1, "deadline_irqs did not grow on the probe run: %s" % rows[-1]
print("live-timer probe OBSERVED: late_us=%d deadline_irqs=%s" % (late, dm.group(1)))
PY
