# live-m16-resources.spec -- milestone-sixteen card K3 (claim 2259)
# class-B gate: kernel resource bounds accounting + pool-full error.
# The task pool is 16 slots (M65d #1442; was 11 when this gate was
# written): shell + worker + idle + THIRTEEN EL0t user slots. Thirteen
# counters fill it (3 + 13 = 16/16 tasks, 1 + 13 = 14/16 procs); the
# fourteenth exec is refused with pool_full. Exact numbers throughout.

vgate_name live-m16-resources "M16 K3 -- resource bounds accounting + pool-full error"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
resources
ls
exec COUNTER.BIN
exec COUNTER.BIN
exec COUNTER.BIN
exec COUNTER.BIN
exec COUNTER.BIN
exec COUNTER.BIN
exec COUNTER.BIN
exec COUNTER.BIN
exec COUNTER.BIN
exec COUNTER.BIN
exec COUNTER.BIN
exec COUNTER.BIN
exec COUNTER.BIN
procs
resources
exec COUNTER.BIN
echo rx-resources-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --timeout 90

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'resources: tasks='
vgate_assert 01 serial-count 'exec: loaded COUNTER.BIN size=' 13
vgate_assert 01 serial-absent 'exec: loaded USER.BIN size='
vgate_assert 01 serial-contains 'resources: procs=14/16'
vgate_assert 01 serial-contains 'resources: tasks=16/16'
vgate_assert 01 serial-contains 'error: no free scheduler pool slot'
vgate_assert 01 serial-contains 'resources: windows='
vgate_assert 01 serial-contains 'resources: tables='
vgate_assert 01 serial-contains 'resources: events=64 mbox=32 fds=8 timers=1 tcp=1'
vgate_assert 01 serial-contains 'rx-resources-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()
rows = re.findall(r'procs:\s+id=\d+\s+name=COUNTER\.BIN\s+uid=\d+\s+caps=\d+\s+state=running\s+task=(\d+)\s+stack=(0x[0-9a-f]+)', ser)
if len(rows) != 13:
    print(f"expected 13 running COUNTER rows, got {len(rows)}", file=sys.stderr); sys.exit(1)
tasks = set(r[0] for r in rows)
stacks = set(r[1] for r in rows)
if len(tasks) != 13 or len(stacks) != 13:
    print("running COUNTER tasks or stacks not all distinct", file=sys.stderr); sys.exit(1)
PY
