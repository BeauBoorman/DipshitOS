# live-sched-ring.spec -- M28 SMP card 10 (claim 1163) class-B gate:
# ring-buffer scheduler wakeups, dual-core task stealing, and the procs
# snapshot on real VZ.

vgate_name live-sched-ring "M28 SMP card 10 -- scheduler ring wakeups and task stealing"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
ls
exec -c1 SCHEDRING.BIN
exec SCHEDRING.BIN
procs
echo rx-schedring-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'SCHEDRING.BIN'
vgate_assert 01 serial-exact 'schedring: slept=4' 2
vgate_assert 01 serial-exact 'schedring: yielded=32' 2
vgate_assert 01 serial-exact 'schedring: done' 2
vgate_assert 01 serial-exact 'tasks user-exec exited status=0' 2
vgate_assert 01 serial-exact 'procs SCHEDRING.BIN exited status=0' 2
vgate_assert 01 serial-exact 'tasks user-exec reaped' 2
vgate_assert 01 serial-contains 'smp: secondary runs='
vgate_assert 01 serial-contains 'smp: steal runs='
vgate_assert 01 serial-contains 'rx-schedring-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()
# NOTE (2026-09-14): the `procs:` row gained `uid=` and `caps=` BETWEEN
# `name=` and `state=` in eb37fbe (M50 TS1, process principals, #1135), which
# this regex was never updated for — so it matched NOTHING and this assertion
# could not pass, independently of any scheduler change. `.*?` spans the
# columns it does not care about; the assertion's meaning (two SCHEDRING
# processes, still running, on DISTINCT tasks) is unchanged.
rows = re.findall(r'procs:\s+id=\d+\s+name=SCHEDRING\.BIN\s+.*?state=running\s+task=(\d+)', ser)
if len(rows) < 2 or rows[0] == rows[1]:
    print(f"expected 2 running SCHEDRING rows with distinct tasks, got {rows}", file=sys.stderr)
    sys.exit(1)
if not re.search(r'smp: secondary runs=\d+ task=SCHEDRING\.BIN', ser):
    print("missing secondary run for SCHEDRING.BIN", file=sys.stderr); sys.exit(1)
if not re.search(r'smp: steal runs=\d+ task=SCHEDRING\.BIN from=\d+', ser):
    print("missing steal from=1 for SCHEDRING.BIN", file=sys.stderr); sys.exit(1)
PY
