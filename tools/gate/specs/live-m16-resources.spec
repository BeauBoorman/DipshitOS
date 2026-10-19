# live-m16-resources.spec -- milestone-sixteen card K3 (claim 2259)
# class-B gate: kernel resource bounds accounting + capacity refusal.
# M129b (#2611): the task pool is 64 slots and the process registry 64
# descriptors — the pool is no longer exec's wall. Each exec'd root
# consumes ~20 pages of the 512-page mmu table carve-out, so ~24 live
# COUNTER.BINs exhaust it: the refusal is `page-table carve-out
# exhausted` (table_full), observed while tasks stay ~28/64. The pool
# itself only saturates through sys_thread tasks (go-stress run 07).

vgate_name live-m16-resources "M16 K3 -- resource bounds accounting + table-carve-out refusal"
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
vgate_assert 01 serial-absent 'exec: loaded USER.BIN size='
vgate_assert 01 serial-contains 'page-table carve-out exhausted'
vgate_assert 01 serial-absent 'error: no free scheduler pool slot'
vgate_assert 01 serial-contains 'resources: windows='
vgate_assert 01 serial-contains 'resources: tables='
vgate_assert 01 serial-contains 'resources: events=64 mbox=32 fds=8 timers=1 tcp=1'
vgate_assert 01 serial-contains 'rx-resources-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()
# M129b: exec's first wall is the 512-page table carve-out (~20 tables
# per live root) — the 64-slot pool is reached only via sys_thread.
# Expect ~23-25 loaded counters before table_full; bound generously.
loads = len(re.findall(r'exec: loaded COUNTER\.BIN size=', ser))
if not (18 <= loads <= 29):
    print(f"expected ~24 COUNTER loads before the carve-out wall, got {loads}", file=sys.stderr); sys.exit(1)
m = re.search(r'resources: tasks=(\d+)/64 zombies=\d+', ser[ser.rindex('resources: tasks='):])
if not m or int(m.group(1)) != 3 + loads:
    print(f"tasks occupancy should be 3 kernel + {loads} counters", file=sys.stderr); sys.exit(1)
m = re.search(r'resources: procs=(\d+)/64', ser[ser.rindex('resources: tasks='):])
if not m or int(m.group(1)) != 1 + loads:
    print(f"procs occupancy should be 1 exited + {loads} counters", file=sys.stderr); sys.exit(1)
rows = re.findall(r'procs:\s+id=\d+\s+name=COUNTER\.BIN\s+uid=\d+\s+caps=\d+\s+state=running\s+task=(\d+)\s+stack=(0x[0-9a-f]+)', ser)
if len(rows) != loads:
    print(f"expected {loads} running COUNTER rows, got {len(rows)}", file=sys.stderr); sys.exit(1)
tasks = set(r[0] for r in rows)
stacks = set(r[1] for r in rows)
if len(tasks) != loads or len(stacks) != loads:
    print("running COUNTER tasks or stacks not all distinct", file=sys.stderr); sys.exit(1)
# The carve-out must be nearly consumed when the refusal fires.
tbl = re.findall(r'resources: tables=(\d+)/512', ser)
if not tbl or int(tbl[-1]) < 450:
    print(f"tables should be near-full at refusal, last={tbl}", file=sys.stderr); sys.exit(1)
PY
