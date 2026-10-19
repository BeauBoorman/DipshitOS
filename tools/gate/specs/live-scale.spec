# live-scale.spec -- pool scale at the 64-slot budget (M129b / #2611;
# was 16 under M65d): counter + up
# to nine USER.BINs live at once (>= 6 running rows, all-distinct
# tasks/stacks), every load runs the EL0 flow, the worker advances
# mid-span, and EITHER a later exec is refused OR every exec fit
# (both prove the substance; both occur across runs). The tables
# carve-out is exec's first wall at 64 (live-m16-resources owns that
# refusal's exact count). No --script-expect (full window).
# Mirrors tools/verify-live-scale.sh (claim 5795 + C3 claim 0339 + #1426).

vgate_name live-scale "ten live programs at the pool budget on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
ls
exec COUNTER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
exec USER.BIN
procs
addrspaces
exec USER.BIN
exec USER.BIN
echo rx-scale-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --timeout 60

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-exact 'rx-scale-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
lines = ser.splitlines()
# Legacy -qE pair (dots unescaped, as in the script): ls rows.
if not re.search(r"^  COUNTER.BIN ", ser, re.M):
    sys.exit("FAIL: no COUNTER.BIN ls row")
if not re.search(r"^  USER.BIN ", ser, re.M):
    sys.exit("FAIL: no USER.BIN ls row")
# Legacy counts: the counter loads once, >= 6 users load and run.
if sum(1 for l in lines if "exec: loaded COUNTER.BIN size=" in l) != 1:
    sys.exit("FAIL: counter load count off")
if sum(1 for l in lines if "exec: loaded USER.BIN size=" in l) < 6:
    sys.exit("FAIL: fewer than 6 user loads")
if sum(1 for l in lines if "user: hello from the ESP" in l) < 6:
    sys.exit("FAIL: fewer than 6 hello markers")
if sum(1 for l in lines if "counter: alive" in l) < 3:
    sys.exit("FAIL: fewer than 3 counter markers")
# Running rows: >= 6, all-distinct tasks AND stacks (the ==8 snapshot
# is a scheduler race -- pinned >= 6 since claim 5069). Procs lines grew
# uid/caps (M50) between name and state.
rows = [l for l in lines
        if re.search(r"procs: id=[0-9]+ name=(COUNTER.BIN|USER.BIN)\b.* state=running", l)]
if len(rows) < 6:
    sys.exit("FAIL: running rows=%d, want >= 6" % len(rows))
tasks = [re.search(r".*task=([0-9]+).*", l).group(1) for l in rows]
stacks = [re.search(r".*stack=0x([0-9a-f]{16}).*", l).group(1) for l in rows]
if len(set(tasks)) != len(rows):
    sys.exit("FAIL: task ids not all distinct")
if len(set(stacks)) != len(rows):
    sys.exit("FAIL: stack VAs not all distinct")
# Interleave: a worker advance strictly between the first and last
# counter markers.
mks = [i for i, l in enumerate(lines) if "counter: alive" in l]
if len(mks) < 2 or not any("tasks worker advances=" in l for l in lines[mks[0] + 1:mks[-1]]):
    sys.exit("FAIL: no worker advance mid-span")
# Capacity: the eleventh exec refused OR every exec fit (>= 9 loads).
pool_full = sum(1 for l in lines if "error: no free scheduler pool slot" in l) >= 1
loads = sum(1 for l in lines if "exec: loaded USER.BIN size=" in l)
if not (pool_full or loads >= 9):
    sys.exit("FAIL: capacity unproven (pool_full=%s loads=%d)" % (pool_full, loads))
# Tables headroom: 0 < used < 512 on the last tables report.
tbl = [l for l in lines if re.search(r"addrspaces: tables=[0-9]+/512", l)]
if not tbl:
    sys.exit("FAIL: no tables report")
used = int(re.search(r".*tables=([0-9]+)/512.*", tbl[-1]).group(1))
if not (0 < used < 512):
    sys.exit("FAIL: tables headroom off used=%d" % used)
# The counter runs at the FINAL procs read.
last = [l for l in lines if re.search(r"procs: id=[0-9]+ name=COUNTER.BIN", l)]
if not last or "state=running" not in last[-1]:
    sys.exit("FAIL: counter not running at the end")
print("scale rows + capacity + tables ok (%d rows, tables=%d)" % (len(rows), used))
PY
