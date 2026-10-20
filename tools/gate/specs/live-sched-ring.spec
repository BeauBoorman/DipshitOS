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

# ---------------------------------------------------------------------------
# Run 02 — M133b (#2756) scheduler aging: a CPU hog's measured share decays
# on its own core. One SCHEDHOG.BIN (pure spin — burns every slice, decays
# to age_max) and two SCHEDINT.BIN interactives (burn + sys_sleep — each
# committed block resets its decay) all pinned to core 1, so the only
# contenders on that ring are the three test tasks. Two `smp` snapshots
# bracket a heartbeat-paced window; the `smp: run` rows carry per-task
# tick attribution, and the python assert computes the hog's windowed
# share and requires it below the bound.
# exec-order: assert-proven -- the hb markers and smp: run rows are
# program/kernel output; a program that never ran still fails the share
# assert (a flaky FAIL, never a false pass).
# ---------------------------------------------------------------------------

vgate_file script_hog.txt <<'EOF'
exec -c1 SCHEDHOG.BIN
exec -c1 SCHEDINT.BIN
exec -c1 SCHEDINT.BIN
EOF

vgate_file snapshot_a.txt <<'EOF'
smp
EOF

vgate_file snapshot_b.txt <<'EOF'
smp
echo rx-schedaging-ok
EOF

vgate_run 02 -- --cpus 2 --script '$RUN_DIR/script_hog.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/snapshot_a.txt' --script2-after "schedint: hb=3" --script3 '$RUN_DIR/snapshot_b.txt' --script3-after "schedint: hb=11" --script-expect "rx-schedaging-ok" --timeout 140

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'exec: loaded SCHEDHOG.BIN size='
vgate_assert 02 serial-exact 'schedhog: armed' 1
vgate_assert 02 serial-exact 'schedint: armed' 2
vgate_assert 02 serial-contains 'schedint: hb=11'
vgate_assert 02 serial-contains 'smp: run task='
vgate_assert 02 serial-contains 'rx-schedaging-ok'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()
# Two `smp` invocations, each emitting one `smp: run` row per live task.
rows = re.findall(r'smp: run task=(\d+) name=(\S+) ticks=(\d+) decay=(\d+) skip=(\d+)', ser)
seen = {}
blocks = []
for task, name, ticks, decay, skip in rows:
    key = (task, name)
    seen.setdefault(key, []).append((int(ticks), int(decay), int(skip)))
# Every live task appears once per snapshot (two snapshots => two entries).
if not any(len(v) >= 2 for v in seen.values()):
    print(f"expected two smp: run snapshots, got {seen}", file=sys.stderr); sys.exit(1)
hog = [(k, v) for k, v in seen.items() if k[1] == "SCHEDHOG.BIN"]
ints = [(k, v) for k, v in seen.items() if k[1] == "SCHEDINT.BIN"]
if len(hog) != 1 or len(ints) != 2:
    print(f"expected 1 hog + 2 interactive rows, got hog={hog} ints={ints}", file=sys.stderr); sys.exit(1)
hog_a, hog_b = hog[0][1][-2], hog[0][1][-1]
int_delta = sum(v[-1][0] - v[-2][0] for _, v in ints)
hog_delta = hog_b[0] - hog_a[0]
total = hog_delta + int_delta
if total <= 0:
    print(f"no measured ticks in window: hog={hog} ints={ints}", file=sys.stderr); sys.exit(1)
share = hog_delta / total
# The decay evidence: the hog sits at the age_max penalty by window end,
# while the sleep-reset interactives are never fully decayed at once.
if hog_b[1] < 5:
    print(f"hog never reached the decay cap: {hog_b}", file=sys.stderr); sys.exit(1)
# Bound (set at claim, M133b #2756): the hog's measured windowed share
# of the three contenders' ticks must decay below 0.40 within the
# hb=3 -> hb=11 window (~8 interactive cycles, ~40+ ticks). Without
# aging, a never-blocked hog soaks every both-blocked tick plus its
# round-robin 1/3 of the contended rest (~0.55+); at age_max=5 the claim
# scan gives it roughly 1-in-(age_max+1) of contended picks only, and
# each SCHEDINT burn (~2 CPU-s) spans ~2 boundaries — long enough to be
# run_ticks-visible at fresh priority but short of the cap.
BOUND = 0.40
print(f"hog share: hog={hog_delta} ints={int_delta} share={share:.3f} bound={BOUND}")
if share >= BOUND:
    print(f"hog share {share:.3f} did not decay below {BOUND}", file=sys.stderr); sys.exit(1)
PY
