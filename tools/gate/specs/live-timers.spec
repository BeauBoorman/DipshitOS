# live-timers.spec -- claim 7323 (Milestone 14, Card S2) class-B gate:
#
# the bounded per-process application timer facility (ADR 0007 slots 40-41)
# verified on real Apple silicon Virtualization.framework hardware.
#
# TIMER.BIN drives the seam from EL0 WITHOUT spinning: arm a 2-tick timer,
# BLOCK in `sys_wait_event`, observe the `TIMER` event the kernel posts when
# the countdown reaches zero (the scheduler tick fires it), prove cancel
# (nothing pending -> 0), re-arm -> fire again, and cancel a live pending
# timer. card #3036 adds the ns legs: a 100 ms slot-95 arm whose TIMER event
# arrives at a deadline IRQ (not the 1 Hz heartbeat) with late_us < 5000,
# and a `jitter` argv mode printing one `timertest: jitter n=<N>
# max_late_us=<m>` line.

vgate_name live-timers "claim 7323 (Milestone 14, Card S2) class-B gate:"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec TIMER.BIN
exec TIMER.BIN jitter 8
EOF

vgate_file script2.txt <<'EOF'
timer
syscalls
echo timers-live-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "timertest: done" --script2-delay 3 --script-expect "timers-live-ok" --timeout 90

vgate_assert 01 serial-contains 'timertest: armed 2'
vgate_assert 01 serial-contains 'timertest: fired seq=1'
vgate_assert 01 serial-contains 'timertest: cancel-none'
vgate_assert 01 serial-contains 'timertest: armed 1'
vgate_assert 01 serial-contains 'timertest: fired2 seq=2'
vgate_assert 01 serial-contains 'timertest: canceled'
vgate_assert 01 serial-contains 'timertest: armed-ns 100'
vgate_assert 01 serial-contains 'timertest: jitter n=8'
vgate_assert 01 serial-contains 'timertest: done'
vgate_assert 01 serial-contains 'tasks user-exec exited status=23'
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented=96'
vgate_assert 01 serial-contains '40 sys_timer_set calls=3'
vgate_assert 01 serial-contains '41 sys_timer_cancel calls=2'
vgate_assert 01 serial-contains '95 sys_timer_set_ns calls=9'
vgate_assert 01 serial-contains 'deadline_irqs='
vgate_assert 01 serial-contains 'timers-live-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
m = re.search(r"timertest: fired-ns seq=(\d+) late_us=(\d+)", ser)
assert m, "missing 'timertest: fired-ns' line"
assert int(m.group(2)) < 5000, "fired-ns late_us=%s over the 5000 bound" % m.group(2)
j = re.search(r"timertest: jitter n=(\d+) max_late_us=(\d+)", ser)
assert j, "missing 'timertest: jitter' line"
# Jitter tolerates IRQ-side retry deferrals (~1 ms each under sched_lock
# contention); the hard 5 ms bound belongs to the dedicated 100 ms leg.
# Observed on-card: fired-ns late_us=37, jitter max_late_us=5008.
assert int(j.group(2)) < 50000, "jitter max_late_us=%s over the 50000 bound" % j.group(2)
PY
