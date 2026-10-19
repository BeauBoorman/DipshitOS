# live-m16-composition.spec -- milestone-sixteen composition class-B gate
# (claim 7289): M16 cards C1 (globals), C2 (fault reap), C3 (pool scale)
# together on real VZ.

vgate_name live-m16-composition "M16 composition -- globals + fault reap + pool scale"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script1.txt <<'EOF'
exec GLOBALS.BIN
EOF

vgate_file script2.txt <<'EOF'
exec COUNTER.BIN
exec GUARD.BIN
EOF

vgate_file script3.txt <<'EOF'
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
resources
procs
echo m16-composition-live-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script1.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "tasks user-exec reaped" --script3 '$RUN_DIR/script3.txt' --script3-after "procs GUARD.BIN exited status=139" --script3-delay 2 --script-expect "m16-composition-live-ok" --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GLOBALS.BIN size=0x0000000000007000'
vgate_assert 01 serial-contains 'data=0x0000000000001010 datapages=2'
vgate_assert 01 serial-contains 'globals: data bss ok'
vgate_assert 01 serial-contains 'guard: stepping off'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-contains 'counter: alive'
vgate_assert 01 serial-contains 'exec: loaded COUNTER.BIN size='
vgate_assert 01 serial-count 'exec: loaded USER.BIN size=' 7
vgate_assert 01 serial-contains 'resources: tasks=11/64'
vgate_assert 01 serial-contains 'resources: procs=11/64'
vgate_assert 01 serial-contains 'resources: tables='
vgate_assert 01 serial-contains 'procs: id='
vgate_assert 01 serial-contains 'm16-composition-live-ok'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()
if not re.search(r'procs:\s+id=\d+\s+name=GLOBALS\.BIN\s+uid=\d+\s+caps=\d+\s+state=exited\s+.*exit=42', ser):
    print("missing GLOBALS.BIN exited status 42", file=sys.stderr); sys.exit(1)
if not re.search(r'fault:\s+GUARD\.BIN\s+far=0x[0-9a-f]+\s+ec=0x24', ser):
    print("missing GUARD.BIN fault ec=0x24", file=sys.stderr); sys.exit(1)
if not re.search(r'procs:\s+id=\d+\s+name=GUARD\.BIN\s+uid=\d+\s+caps=\d+\s+state=exited\s+.*exit=139', ser):
    print("missing GUARD.BIN exited status 139", file=sys.stderr); sys.exit(1)
rows = re.findall(r'procs:\s+id=\d+\s+name=(?:COUNTER|USER)\.BIN\s+uid=\d+\s+caps=\d+\s+state=running\s+task=(\d+)\s+stack=(0x[0-9a-f]+)', ser)
if len(rows) != 8:
    print(f"expected 8 running rows, got {len(rows)}", file=sys.stderr); sys.exit(1)
tasks = set(r[0] for r in rows)
stacks = set(r[1] for r in rows)
if len(tasks) != 8 or len(stacks) != 8:
    print("running tasks or stacks not all distinct", file=sys.stderr); sys.exit(1)
PY
